import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F494 review — F494 made `importOne`'s free-space sum saturate, and its twin in the watched folder's
// batch precompute, `watchedFolderImportRefusalMessage`, still added with a trapping `+`: once per
// file into the batch total, and once more for the 500 MB margin. `Int64` addition traps on
// overflow, so a batch whose sizes add up past `Int64.max` took the app down from a three-second
// look instead of being refused as too big. No volume makes files that size (APFS stops at
// 2^55 - 1 bytes on the Mac this was written on), so the size seam stands in for them; the
// precompute's arithmetic is real.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportStorageOverflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// A real, parseable WAV, so a check that wrongly let it through would have something to import.
private func makeRecordingFile(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportStorageOverflowFiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

/// Counts calls into the copy seam, which runs on the import's detached task.
private final class CopyAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}

/// The figure a refusal names when the need saturated: `Int64.max`, formatted the way the message
/// formats it, so the assertion is about the number, not about this machine's locale.
private let saturatedFigure = ByteCountFormatter.string(fromByteCount: Int64.max, countStyle: .file)

/// The size checks are skipped when the volume reports no free-space figure, so require that it
/// does: otherwise these tests would fail as claims about arithmetic when they are facts about the host.
@MainActor
private func requireFreeSpaceFigure(_ model: AppModel) throws {
    model.refreshRecordingPreflight()
    try #require(model.recordingPreflight.availableStorageBytes != nil)
}

@MainActor
@Test("A watched batch whose sizes add up past Int64 is refused for space, not a crash (F494)")
func watchedBatchPastInt64IsRefusedNotTrapped() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let first = try makeRecordingFile(named: "a.wav")
    defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    let second = try makeRecordingFile(named: "b.wav")
    defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
    // Each fits in an Int64; the two together do not. The batch total is where it overflowed.
    model.measureImportSource = { _ in Int64.max }
    let copies = CopyAttempts()
    model.copyRecordingIntoLibrary = { _, _ in
        copies.record()
        throw CocoaError(.fileWriteUnknown)
    }
    try requireFreeSpaceFigure(model)

    model.watchedFolderLooked(snapshot: nil, ready: [first, second])
    await model.watchedFolderDelivery?.value

    #expect(copies.count == 0, "refused before any copy, as a batch that does not fit is")
    #expect(model.pendingWatchedFiles == [first, second], "and held on the queue, not dropped")
    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains(saturatedFigure), "the need reads as the largest figure, not a wrapped one: \(alert)")
}

@MainActor
@Test("A watched file within the margin of Int64's limit is refused for space, not a crash (F494)")
func watchedFileWithinTheMarginOfInt64IsRefusedNotTrapped() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile(named: "a.wav")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    // The batch total fits; adding the 500 MB margin to it does not. That second sum is where it
    // overflowed.
    model.measureImportSource = { _ in Int64.max - 100 }
    let copies = CopyAttempts()
    model.copyRecordingIntoLibrary = { _, _ in
        copies.record()
        throw CocoaError(.fileWriteUnknown)
    }
    try requireFreeSpaceFigure(model)

    model.watchedFolderLooked(snapshot: nil, ready: [file])
    await model.watchedFolderDelivery?.value

    #expect(copies.count == 0)
    #expect(model.pendingWatchedFiles == [file])
    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains(saturatedFigure), "\(alert)")
}

// Control: `importOne`'s own check already saturated, since F494's symlink fix, and nothing tested
// it. The two checks share their arithmetic now, so this pins that the per-file one still survives
// a size the batch one did not.
@MainActor
@Test("A file the user imports that is too big to add a margin to is refused for space (F494 control)")
func userImportPastInt64IsRefusedForSpace() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile(named: "a.wav")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    model.measureImportSource = { _ in Int64.max }
    let copies = CopyAttempts()
    model.copyRecordingIntoLibrary = { _, _ in
        copies.record()
        throw CocoaError(.fileWriteUnknown)
    }
    try requireFreeSpaceFigure(model)

    let imported = await model.importRecording(from: file, title: "")

    #expect(imported == nil)
    #expect(copies.count == 0)
    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains(saturatedFigure), "\(alert)")
}
