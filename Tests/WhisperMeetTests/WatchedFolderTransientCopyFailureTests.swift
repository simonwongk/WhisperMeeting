import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F554 — a watched-folder import whose copy fails for a reason that is not the file's (the disk
// filled, the share dropped, an I/O error) was refused as `permanent`. Permanent leaves the file to
// the inbox, and the inbox offers a file again only once it changes, so a recording that failed to
// copy for one of these reasons was never imported, though nothing about the file was wrong.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F554-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// A real, parseable WAV: the import measures its duration before adopting it (F326).
private func makeRecordingFile(named name: String = "call.wav") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F554Source-\(UUID().uuidString)", isDirectory: true)
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

/// A share that dropped mid-copy: an unspecific read error, with the reason only underneath it.
private let shareDropped: Error = NSError(
    domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))]
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
@Test("A watched file whose copy ran out of space is kept and imported on a later look (F554)")
func outOfSpaceCopyIsRetried() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 1, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    await look(model, ready: [file])

    #expect(copy.calls == 1)
    #expect(model.store.meetings.isEmpty)
    #expect(model.pendingWatchedFiles == [file], "nothing was wrong with the file, so it stays queued")
    #expect(model.alertMessage == nil, "a failure the queue is still retrying is held silently (F454)")

    await look(model)

    #expect(copy.calls == 2)
    #expect(model.store.meetings.count == 1, "the retry imports it, once")
    #expect(model.pendingWatchedFiles.isEmpty)
    #expect(!model.isImporting)
}

@MainActor
@Test("A copy that keeps failing is given up on after a bounded number of tries, with one alert (F554)")
func persistentTransientFailureIsBounded() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: .max, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    var alerts: [String] = []
    await look(model, ready: [file])
    for _ in 0..<20 {
        if let alert = model.alertMessage { alerts.append(alert) }
        model.alertMessage = nil
        if model.pendingWatchedFiles.isEmpty { break }
        await look(model)
    }

    #expect(copy.calls == AppModel.watchedFolderCopyAttemptLimit,
            "retried, but exactly as often as the limit says: every try re-copies the whole file")
    #expect(model.pendingWatchedFiles.isEmpty)
    #expect(model.store.meetings.isEmpty)
    #expect(alerts.count == 1, "the give-up is said once, not once per try: \(alerts)")
    let alert = try #require(alerts.first)
    #expect(alert.contains("call.wav"))
    #expect(alert.contains("Import Recordings"), "and says how to import it once the problem is fixed")

    #expect(model.watchedFolderAnnouncementCount == 1, "announced once, not once per try")

    let triesAtGiveUp = copy.calls
    await look(model)
    #expect(copy.calls == triesAtGiveUp, "a file given up on is not tried again on its own")

    // The inbox offers it again only once it has changed, and then it is news again.
    await look(model, ready: [file])
    #expect(model.watchedFolderAnnouncementCount == 2, "a file handed over afresh is announced afresh")
    #expect(model.lastWatchedFolderAnnouncement == "Importing from your watched folder: call.wav")
}

// F554 review — every retry is a new delivery, and each delivery posted "Importing from your
// watched folder: …" again, so a copy that kept failing announced itself once per try, each time
// followed by nothing, before the give-up alert: the repeat F454's once-per-cause rule exists to
// prevent. A file is announced when it first goes to the importer, and not again until it leaves
// the queue.
@MainActor
@Test("A file being retried is announced once, not once per try (F554)")
func retriedFileIsAnnouncedOnce() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 2, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    await look(model, ready: [file])
    await look(model)
    await look(model)

    try #require(copy.calls == 3)
    try #require(model.store.meetings.count == 1, "the third try imports it")
    #expect(model.watchedFolderAnnouncementCount == 1, "three tries, one announcement")
    #expect(model.lastWatchedFolderAnnouncement == "Importing from your watched folder: call.wav")
}

@MainActor
@Test("A new file joining a file being retried is announced by its own name only (F554)")
func newFileBesideARetryIsAnnouncedAlone() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let first = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    let second = try makeRecordingFile(named: "standup.wav")
    defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 1, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    await look(model, ready: [first])
    try #require(model.pendingWatchedFiles == [first])
    #expect(model.lastWatchedFolderAnnouncement == "Importing from your watched folder: call.wav")
    await look(model, ready: [second])

    try #require(model.store.meetings.count == 2, "both import on the second look")
    #expect(model.watchedFolderAnnouncementCount == 2)
    #expect(model.lastWatchedFolderAnnouncement == "Importing from your watched folder: standup.wav",
            "the file being retried was announced on the first look, so only the new one is named")
}

@MainActor
@Test("While the watched folder cannot be read, a file waiting to be retried is held, not re-copied (F554)")
func retryWaitsForTheFolderToComeBack() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: 1, with: shareDropped)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    await look(model, ready: [file])
    #expect(copy.calls == 1)
    #expect(model.pendingWatchedFiles == [file])

    // The share is gone: the monitor reports the folder missing on every look until it is back.
    for _ in 0..<5 {
        await look(model, problem: .missing)
    }
    #expect(copy.calls == 1, "a folder that cannot be listed cannot be copied from either")
    #expect(model.pendingWatchedFiles == [file], "and waiting for it costs the file nothing")

    await look(model)

    #expect(copy.calls == 2)
    #expect(model.store.meetings.count == 1)
    #expect(model.pendingWatchedFiles.isEmpty)
}

@MainActor
@Test("A copy refused for a reason that will not pass is still not retried (F554 control)")
func permanentCopyFailureIsNotRetried() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let denied = NSError(
        domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
    )
    let copy = ScriptedCopy(failing: .max, with: denied)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    await look(model, ready: [file])

    #expect(copy.calls == 1)
    #expect(model.pendingWatchedFiles.isEmpty)
    #expect(model.alertMessage?.contains("could not be imported") == true)
}

@MainActor
@Test("A file the user imported themselves still reports an out-of-space copy at once (F554 control)")
func userImportStillReportsTransientFailure() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let copy = ScriptedCopy(failing: .max, with: outOfSpace)
    model.copyRecordingIntoLibrary = { try copy.copy($0, $1) }

    let imported = await model.importRecording(from: file, title: "")

    #expect(imported == nil)
    #expect(copy.calls == 1)
    #expect(model.alertMessage?.contains("could not be imported") == true, "nothing retries it, so it is said now")
}
