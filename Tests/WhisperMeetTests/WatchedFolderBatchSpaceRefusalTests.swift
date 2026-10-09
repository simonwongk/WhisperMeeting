import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F706 — the watched folder checks free space for its whole waiting batch at once (F454), but said so
// in `importOne`'s per-file words: "Importing this recording needs about <size> free". With several
// files waiting, the alert said "this recording" and gave the figure for all of them, so the user
// could not tell which file it meant or that it covered more than one. The size seam stands in for
// the sizes; the batch check, its sum and its message are production code.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F706-\(UUID().uuidString)", isDirectory: true)
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
        .appendingPathComponent("F706Files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

/// The volume's free space as the check reads it. Required, because the check is skipped when the
/// volume reports none: these tests would otherwise fail as claims about wording when they are facts
/// about the host.
@MainActor
private func requireFreeSpace(_ model: AppModel) throws -> Int64 {
    model.refreshRecordingPreflight()
    return try #require(model.recordingPreflight.availableStorageBytes)
}

@MainActor
@Test("A batch refused for space says how many recordings it is holding and names them (F706)")
func batchRefusedForSpaceNamesItsRecordings() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let first = try makeRecordingFile(named: "monday standup.wav")
    defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    let second = try makeRecordingFile(named: "client call.m4a")
    defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
    // Three quarters of the free space each: on any volume with more than 2 GB free, either file
    // alone fits with the 500 MB margin, and the two together never do. The assertions below hold
    // either way; this is the shape that makes "this recording" wrong.
    let available = try requireFreeSpace(model)
    let each = available / 4 * 3
    model.measureImportSource = { _ in each }

    model.watchedFolderLooked(snapshot: nil, ready: [first, second])
    await model.watchedFolderDelivery?.value

    #expect(model.pendingWatchedFiles == [first, second], "held on the queue, as a batch that does not fit is")
    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(!alert.contains("this recording"), "it is holding two: \(alert)")
    #expect(alert.contains("2 recordings"), "\(alert)")
    #expect(alert.contains("monday standup.wav") && alert.contains("client call.m4a"), "\(alert)")
}

@MainActor
@Test("A single waiting file refused for space is named, and called one recording (F706)")
func singleWatchedFileRefusedForSpaceIsNamed() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile(named: "monday standup.wav")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let available = try requireFreeSpace(model)
    model.measureImportSource = { _ in available }

    model.watchedFolderLooked(snapshot: nil, ready: [file])
    await model.watchedFolderDelivery?.value

    #expect(model.pendingWatchedFiles == [file])
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("monday standup.wav"), "\(alert)")
    #expect(!alert.contains("recordings"), "one file is one recording: \(alert)")
}
