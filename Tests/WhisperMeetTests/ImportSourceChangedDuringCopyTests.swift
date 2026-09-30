import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F698 — F326's copy-time re-check: a file that changes while it is being copied into the library is
// refused, not adopted as a prefix of the real recording. The re-check read the source's size and
// date twice through the same `URL`, and Foundation's per-URL resource-value cache handed the second
// read the first one's values, so it never saw a change.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportRecheck-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F698.\(UUID().uuidString)")!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// A real, parseable WAV: the import measures its duration before adopting it (F326).
private func makeRecordingFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportRecheckSource-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("call.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

/// What a writer that paused and then resumed does: more bytes land after the copy took its own.
private func appendToSource(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0, count: 4_096))
}

@MainActor
private func libraryRecordingFolders(of model: AppModel) -> [String] {
    let recordings = model.store.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
}

@MainActor
@Test("A recording that grows while it is being copied is refused, not adopted as a prefix (F698)")
func sourceGrowingDuringTheCopyIsRefused() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    model.copyRecordingIntoLibrary = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
        try appendToSource(source)
    }

    let imported = await model.importRecording(from: file, title: "")

    #expect(imported == nil, "the library's copy is a prefix of what is on disk now")
    #expect(model.store.meetings.isEmpty)
    #expect(libraryRecordingFolders(of: model).isEmpty, "the partial copy is removed, not left unindexed")
    #expect(model.alertMessage?.contains("still being written") == true)
    #expect(!model.isImporting)
}

@MainActor
@Test("A recording that holds still while it is copied imports as before (F698 control)")
func sourceHoldingStillDuringTheCopyImports() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let imported = await model.importRecording(from: file, title: "")

    let id = try #require(imported)
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.duration > 0)
    #expect(try Data(contentsOf: model.store.recordingURL(for: meeting)) == Data(contentsOf: file))
}
