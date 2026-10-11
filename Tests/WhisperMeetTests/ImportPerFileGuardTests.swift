import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F707 review (R3) — `importRecordings` checks `libraryAcceptsChanges` once for the batch, and
// `importOne` checks it again for each file. Since the tests moved onto `importRecordings` (F707),
// the batch check runs first in every one of them, so nothing reached the per-file check: deleting it
// passed the suite. It is the F187 protection for a batch whose library stops accepting changes
// between files — here, a whole-library restore that starts after the first file is adopted, before
// the second is copied. The second file must then be refused before anything of it is copied.

@MainActor
@Test("A restore that starts during a batch stops the files after it, before they are copied (F707 review)")
func importBatchStopsAtARestoreBetweenFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportPerFileGuard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let first = sources.appendingPathComponent("first.wav")
    let second = sources.appendingPathComponent("second.wav")
    for url in [first, second] {
        try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    }
    let model = AppModel(store: MeetingStore(rootDirectory: root.appendingPathComponent("library")),
                         recorder: AudioCaptureEngine(), defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    // The restore starts between the files. Adopting the first file refreshes the runtime probes on
    // the main actor after its meeting is saved, and before the second file's `importOne`; that is
    // where this seam begins it, the first time it is asked. No thread waits on another.
    let restoreBegun = Flag()
    model.checkQwenInstalled = {
        MainActor.assumeIsolated {
            if !restoreBegun.value {
                restoreBegun.set()
                model.store.beginLibraryRestore()
            }
        }
        return false
    }
    defer { model.store.endLibraryRestore() }
    let copied = CopiedSources()
    model.copyRecordingIntoLibrary = { source, destination in
        copied.record(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    let outcome = await model.importRecordings(from: [first, second], title: "")

    try #require(restoreBegun.value, "the restore never started, so this test proves nothing")
    #expect(model.store.meetings.count == 1, "the first file was imported before the restore began")
    #expect(copied.names == ["first.wav"], "the second file was copied into a library being restored")
    #expect(outcome.notImported.map(\.lastPathComponent) == ["second.wav"],
            "kept for later, not dropped: the refusal is retryable")
    #expect(model.alertMessage == AppModel.libraryRestoringMessage("Import"), "\(model.alertMessage ?? "nil")")
    #expect(!model.isImporting)
}

/// Set once, read from a `@Sendable` seam.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.withLock { _value = true } }
    var value: Bool { lock.withLock { _value } }
}

/// The names the copy seam was called with, in order; the seam runs on the import's detached task.
private final class CopiedSources: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    func record(_ name: String) { lock.withLock { _names.append(name) } }
    var names: [String] { lock.withLock { _names } }
}
