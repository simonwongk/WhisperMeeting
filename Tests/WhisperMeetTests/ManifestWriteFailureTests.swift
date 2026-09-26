import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F502 — `stop()` used to rethrow any `SourceTrackManifest.write` failure after `meeting.wav` was
// already complete, which sent `AppModel.stopRecording` down its "recovered after a finishing
// error" path for a recording that had lost nothing but a sidecar description of its own raw
// tracks. That path builds its `MeetingRecord` from a `RecoveredRecording`, which carries no
// `healthReport` at all, and it skips the success path's automatic transcription.
//
// A directory sitting at `source-tracks.json`'s own path is a deterministic way to fail that write
// — `Data.write(to:options:.atomic)` cannot create a regular file over an existing directory — so
// this needs no injected seam and no permission trick.

private func sessionDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F502-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func injectedEngine(_ directory: URL) -> AudioCaptureEngine {
    AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: directory
    )
}

@Test("A manifest write failure after a complete mix does not fail Stop or drop the health report (F502)")
func manifestWriteFailureAfterCompleteMixDoesNotFailStop() async throws {
    let directory = try sessionDirectory("manifestfail")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = injectedEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)
    // Forces `SourceTrackManifest.write`'s atomic write to fail deterministically: it cannot create
    // a regular file where a directory already sits.
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("source-tracks.json"),
        withIntermediateDirectories: true
    )

    let artifact = try await engine.stop()

    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    #expect(abs(artifact.duration - 1.0) < 0.01)
    #expect(artifact.healthReport != nil, "the health rollup must survive a manifest write failure")
}
