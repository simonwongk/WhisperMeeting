import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F292 — what the user's real lid-close test showed on 2026-09-18 (installed build 6b7cfdb, docked
// to an external display): the capture died 13.7 s in, and pressing Stop produced "recovered after a
// finishing error" — a zero-aligned rebuild, no transcription — because `stop()` rethrew the death.
// The five-agent trace of the current code found that half of it survived every fix since: `stop()`
// still threw on any recorded stream error, and after a failed restart (`stream == nil`) it threw at
// its guard before `reset()` could run. These tests drive the engine's real track writers.

private func sessionDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeadCaptureStop-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct StreamDied: Error {}

private func injectedEngine(_ directory: URL) -> AudioCaptureEngine {
    AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: directory
    )
}

@Test("Stop after the capture died saves what was captured, aligned, instead of a finishing error (F292)")
func stopAfterDeathFinalizesNormally() async throws {
    let directory = try sessionDirectory("died")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = injectedEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    // The measured shape: system audio from t=0, the microphone 0.2 s later, both ending at the
    // lid close.
    try engine.writeTestFrames(system: 48_000 * 13, microphone: 48_000 * 13 - 9_600,
                               systemStart: 100.0, microphoneStart: 100.2)
    engine.handleStreamFailure(StreamDied())

    let artifact = try await engine.stop()

    #expect(artifact.captureStoppedEarly, "the meeting must be able to say the audio ends early")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    // The alignment itself, not the presence of the key: a zero-aligned rebuild writes
    // `startOffsetSeconds` too, and 13 s is the duration either way.
    let manifest = try manifestJSON(in: directory)
    #expect(manifest["recoveryAlignment"] as? String == "captured-timeline")
    let microphone = try #require(manifest["microphoneAudio"] as? [String: Any])
    #expect(abs((microphone["startOffsetSeconds"] as? Double ?? 0) - 0.2) < 0.001)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovered.wav").path))
    #expect(abs(artifact.duration - 13.0) < 0.01)
}

private func manifestJSON(in directory: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: directory.appendingPathComponent("source-tracks.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("A buffer that failed to write is not a capture that stopped early (F292)")
func writeFailureIsNotAnEarlyStop() async throws {
    let directory = try sessionDirectory("writefail")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = injectedEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)
    engine.recordWriteFailureForTesting(StreamDied())
    let artifact = try await engine.stop()
    #expect(!artifact.captureStoppedEarly, "a stream that kept running did not end early")
}

@Test("A capture that did not die is not described as ending early (F292)")
func healthyStopIsNotEarly() async throws {
    let directory = try sessionDirectory("healthy")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = injectedEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 5, microphoneStart: 5)
    let artifact = try await engine.stop()
    #expect(!artifact.captureStoppedEarly)
}

@Test("After a failed restart left no stream, Stop still saves and releases everything (F292)")
func stopWithNoStreamStillResets() async throws {
    let directory = try sessionDirectory("nostream")
    defer { try? FileManager.default.removeItem(at: directory) }
    // The real engine, not the injected one: a restart that failed in `makeStream` leaves exactly
    // this — writers open, `stream == nil`, the old death recorded, the power assertion held.
    let engine = AudioCaptureEngine()
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 1, microphoneStart: 1)
    engine.beginRecordingActivity()
    engine.handleStreamFailure(StreamDied())

    let artifact = try await engine.stop()

    #expect(artifact.captureStoppedEarly)
    #expect(!engine.isHoldingRecordingActivity, "the Mac was kept awake after the recording ended")
    #expect(!engine.hasStreamError, "the old death leaked into the next recording")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    init(failures: Int) { failuresLeft = failures }
    func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; failuresLeft -= 1; return failuresLeft >= 0 }
}

private struct RestartFailed: Error {}

private func restartEngine(_ directory: URL, failures: Int = 0, delay: Duration = .zero) -> AudioCaptureEngine {
    let flag = Flag(failures: failures)
    return AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in
            if delay != .zero { try? await Task.sleep(for: delay) }
            if flag.shouldFail() { throw RestartFailed() }
        },
        directory: directory
    )
}

@Test("Restart padding is written once, when the capture resumes, and labels the manifest (F292)")
func restartPaddingIsWrittenOnceOnSuccess() async throws {
    let directory = try sessionDirectory("padding")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = restartEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000 * 10, microphone: 48_000 * 10, systemStart: 0, microphoneStart: 0)
    engine.handleStreamFailure(StreamDied())

    try await engine.restartAfterFailure(paddingFrames: 48_000 * 3)

    #expect(engine.testFrameCounts == (system: 48_000 * 13, microphone: 48_000 * 13))
    #expect(engine.restartCount == 1)
    #expect(!engine.hasStreamError, "a successful restart must clear the death")
    let artifact = try await engine.stop()
    #expect(!artifact.captureStoppedEarly, "a capture that resumed did not end early")
    #expect(try manifestJSON(in: directory)["recoveryAlignment"] as? String == "padded-after-restart")
}

@Test("A failed restart writes no padding, keeps the death, and the retry pads the outage once (F292)")
func failedRestartPadsNothingAndRetryPadsOnce() async throws {
    let directory = try sessionDirectory("retry")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = restartEngine(directory, failures: 1)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000 * 10, microphone: 48_000 * 10, systemStart: 0, microphoneStart: 0)
    engine.handleStreamFailure(StreamDied())

    await #expect(throws: RestartFailed.self) { try await engine.restartAfterFailure(paddingFrames: 48_000 * 3) }
    #expect(engine.testFrameCounts == (system: 48_000 * 10, microphone: 48_000 * 10), "a failed restart padded")
    #expect(engine.hasStreamError, "the retry needs the death to stay recorded")
    #expect(engine.restartCount == 0)

    // The retry measures the whole outage (now 5 s) and pays it exactly once.
    try await engine.restartAfterFailure(paddingFrames: 48_000 * 5)
    #expect(engine.testFrameCounts == (system: 48_000 * 15, microphone: 48_000 * 15))
}

@Test("A restart that outlives Stop gives up instead of starting a capture nothing will stop (F292)")
func restartOutlivingStopIsAbandoned() async throws {
    let directory = try sessionDirectory("outlive")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = restartEngine(directory, delay: .milliseconds(300))
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)
    engine.handleStreamFailure(StreamDied())

    let restart = Task { try await engine.restartAfterFailure(paddingFrames: 48_000) }
    try await Task.sleep(for: .milliseconds(50))
    let artifact = try await engine.stop()
    #expect(artifact.captureStoppedEarly, "a stop during a restart is stopping a capture that died")
    await #expect(throws: CancellationError.self) { try await restart.value }

    #expect(engine.restartCount == 0, "the abandoned restart counted itself into the next recording")
    #expect(!engine.hasStreamError, "the abandoned restart put its death back into a reset engine")
    #expect(engine.testFrameCounts == (system: 0, microphone: 0))
}
