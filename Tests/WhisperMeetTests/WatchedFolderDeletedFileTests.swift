import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F709 — F554 treats "no such file" as transient, because a source on a share that dropped reads that
// way and is back when the share is. So a queued file the user DELETED failed the same way on every
// try, and after three the queue posted "Not imported from your watched folder after 3 tries", whose
// next step — import it with Import Recordings… — does not apply to a file that is gone. When the
// folder itself is there, a missing file was deleted or moved away: it is forgotten, silently.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F709-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// A real, parseable WAV in a folder of its own, which stands in for the watched folder.
private func makeRecordingFile(named name: String = "call.wav") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F709Source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

/// The disk filling mid-copy, in the shape Foundation reports it: a Cocoa error wrapping the POSIX one.
private let outOfSpace: Error = NSError(
    domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
)

/// A copy seam that fails its first `failures` calls with `error`, then copies for real, and counts
/// every call. Called on the import's detached task, hence the lock.
private final class ScriptedCopy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let failures: Int
    private let error: Error

    init(failing failures: Int, with error: Error) {
        self.failures = failures
        self.error = error
    }

    var calls: Int { lock.withLock { _calls } }

    func copy(_ source: URL, _ destination: URL) throws {
        let call = lock.withLock { () -> Int in
            _calls += 1
            return _calls
        }
        if call <= failures { throw error }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

@MainActor
private func look(_ model: AppModel, ready: [URL] = [], problem: WatchedFolderMonitor.Problem? = nil) async {
    model.watchedFolderLooked(snapshot: nil, ready: ready, problem: problem)
    await model.watchedFolderDelivery?.value
}

@MainActor
@Test("A file waiting to be retried that the user deleted is forgotten, with no alert and no more copies (F709)")
func deletedRetryIsForgottenSilently() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 1, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }
    await look(model, ready: [file])
    try #require(copy.calls == 1)
    try #require(model.pendingWatchedFiles == [file], "waiting to be retried")

    // The user deletes it while it waits. Its folder is still there and was just listed.
    try FileManager.default.removeItem(at: file)
    var alerts: [String] = []
    for _ in 0..<(AppModel.watchedFolderCopyAttemptLimit + 1) {
        await look(model)
        if let alert = model.alertMessage { alerts.append(alert) }
        model.alertMessage = nil
    }

    #expect(model.pendingWatchedFiles.isEmpty, "a file that is gone is not waiting for anything")
    #expect(copy.calls == 1, "and is not copied again")
    #expect(alerts.isEmpty, "there is nothing to tell the user about a file they deleted: \(alerts)")
    #expect(model.watchedFolderAnnouncementCount == 1)
    #expect(model.store.meetings.isEmpty)
}

@MainActor
@Test("A file the user deleted while it waited for a recording to end is forgotten before any copy (F709)")
func deletedWaitingFileIsNeverCopied() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 0, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    await look(model, ready: [file])
    try #require(model.pendingWatchedFiles == [file], "held while the recording runs")

    try FileManager.default.removeItem(at: file)
    model.setRecordingStateForTesting(.idle)
    await look(model)

    #expect(model.pendingWatchedFiles.isEmpty)
    #expect(copy.calls == 0)
    #expect(model.watchedFolderAnnouncementCount == 0, "nothing is announced for a file that is gone")
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("While the watched folder cannot be read, a missing file is held, not forgotten (F709 control)")
func missingFileIsHeldWhileTheFolderCannotBeRead() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 1, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }
    await look(model, ready: [file])
    try #require(model.pendingWatchedFiles == [file])

    // A share that dropped: the file reads as missing, and so does the folder (F554).
    try FileManager.default.removeItem(at: file)
    await look(model, problem: .missing)

    #expect(model.pendingWatchedFiles == [file], "a share that comes back brings the file back")
    #expect(copy.calls == 1)
}

@MainActor
@Test("A missing file whose folder is missing too is kept: a volume that went away looks the same (F709 control)")
func missingFileWithoutItsFolderIsKept() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    let folder = file.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    let copy = ScriptedCopy(failing: 1, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }
    await look(model, ready: [file])
    try #require(model.pendingWatchedFiles == [file])

    // The folder went with the file, as it does when a volume is unmounted between the listing
    // and the delivery. That cannot be told from a deletion, so the file is not forgotten.
    try FileManager.default.removeItem(at: folder)
    await look(model)

    #expect(model.pendingWatchedFiles == [file])
    #expect(model.alertMessage == nil)
}
