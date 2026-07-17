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

private func writeFloatSamples(_ samples: [Float], to url: URL) throws {
    let data = samples.withUnsafeBytes { Data($0) }
    try data.write(to: url)
}
