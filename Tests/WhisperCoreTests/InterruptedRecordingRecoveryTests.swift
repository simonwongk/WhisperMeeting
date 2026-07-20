import Foundation
import Testing
@testable import WhisperCore

@Test("Interrupted raw source tracks rebuild a usable WAV without deleting originals")
func rebuildsInterruptedRecording() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let systemURL = directory.appendingPathComponent("system-audio.f32")
    let microphoneURL = directory.appendingPathComponent("microphone-audio.f32")
    try writeFloatSamples([0.5, 0], to: systemURL)
    try writeFloatSamples([0, 0.5], to: microphoneURL)

    let result = try InterruptedRecordingRecovery.recover(
        in: directory,
        sampleRate: 48_000
    )
    let recovered = try #require(result)

    #expect(recovered.wasRebuiltFromRawTracks)
    #expect(recovered.duration == 2.0 / 48_000.0)
    #expect(FileManager.default.fileExists(atPath: recovered.recordingURL.path))
    #expect(FileManager.default.fileExists(atPath: systemURL.path))
    #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
    #expect(try Data(contentsOf: recovered.recordingURL).prefix(4) == Data("RIFF".utf8))
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("source-tracks.recovered.json").path
    ))
}

@Test("An empty failed-start folder is removed without touching non-empty folders")
func removesOnlyEmptyFailedStartFolders() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetEmptyRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    let emptyDirectory = root.appendingPathComponent("empty", isDirectory: true)
    let nonEmptyDirectory = root.appendingPathComponent("non-empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nonEmptyDirectory, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: nonEmptyDirectory.appendingPathComponent("unknown-data"))
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try InterruptedRecordingRecovery.removeIfEmpty(in: emptyDirectory))
    #expect(!FileManager.default.fileExists(atPath: emptyDirectory.path))
    #expect(try !InterruptedRecordingRecovery.removeIfEmpty(in: nonEmptyDirectory))
    #expect(FileManager.default.fileExists(atPath: nonEmptyDirectory.path))
}

@Test("An imported recording folder with no source tracks is recognized, not discarded")
func recoversImportedRecording() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetImportRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let importedURL = directory.appendingPathComponent("recording.m4a")
    try Data("fake compressed audio".utf8).write(to: importedURL)

    let recovered = try #require(try InterruptedRecordingRecovery.recover(in: directory))

    #expect(!recovered.wasRebuiltFromRawTracks)
    #expect(recovered.recordingURL.lastPathComponent == "recording.m4a")
    #expect(
        recovered.recordingURL.resolvingSymlinksInPath().path
            == importedURL.resolvingSymlinksInPath().path
    )
    #expect(FileManager.default.fileExists(atPath: importedURL.path))
}

private func writeFloatSamples(_ samples: [Float], to url: URL) throws {
    let data = samples.withUnsafeBytes { Data($0) }
    try data.write(to: url)
}
