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

@Test("A writer with no first buffer yet is not padded, and the manifest anchors the gap on the one that was (F460)")
func restartPaddingSkipsAnUnstartedWriter() async throws {
    // The scenario the ticket names: the user starts recording before any system audio plays, so
    // the microphone has been capturing since t=0 and the system track has never received a
    // buffer at all. Before this fix, `applyPendingRestartPaddingIfNeeded` padded BOTH writers
    // from a restart mid-recording, so the system track's file started with silence it had no
    // `firstPresentationTime` to anchor. When real system audio eventually arrived, its OWN first
    // buffer set `firstPresentationTime` from its own timestamp — ignoring the silence already
    // ahead of it — so the mixer's front-padding (from that timestamp) stacked on top, shifting
    // the whole channel late, and the manifest's `paddedGaps` entry was anchored at frame 0 of a
    // track that had not started, i.e. "the gap at 0:00".
    let directory = try sessionDirectory("unstarted")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = restartEngine(directory)
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(microphoneOnly: 48_000 * 10, firstPresentationTime: 0)
    engine.handleStreamFailure(StreamDied())

    try await engine.restartAfterFailure(paddingFrames: 48_000 * 3)

    // The system writer got NO padding: writing it there would only become visible once its real
    // audio starts, as an extra silent span the mixer's own front-padding does not know about.
    #expect(engine.testFrameCounts == (system: 0, microphone: 48_000 * 13))

    // System audio starts for real, 20 s after the recording began.
    try engine.writeTestFrames(system: 48_000 * 5, microphone: 0, systemStart: 20, microphoneStart: 0)
    _ = try await engine.stop()

    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    let manifest = try manifestJSON(in: directory)
    let gaps = try #require(manifest["paddedGaps"] as? [[String: Any]])
    #expect(gaps.count == 1)
    // Anchored on the microphone — the writer that was ACTUALLY padded — not on a system writer
    // whose frame count was 0 and would have wrongly put the gap at 0:00.
    #expect(abs((gaps.first?["startSeconds"] as? Double ?? -1) - 10.0) < 0.001)
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

// F632 — F388 moved `stop()`'s normal finalize onto `captureQueue`, where the sample handler and
// the restart padding write the same two writers; the abort-path finalizer, `preservePartialTracks()`,
// still called `finish()` from whichever thread stop() was on. This drives the REAL body (the
// injected init's `preservingPartialTracks: nil`) down stop()'s first catch — the stream refused to
// stop and did not die, so it may still be delivering — and records where each track's
// finish-time flush ran. 48 000 frames is 192 KB, under the 960 KB periodic-sync interval, so
// finish() is the only thing that reaches the probe.

private final class QueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [Bool] = []
    func record() { lock.lock(); observed.append(AudioCaptureEngine.isOnCaptureQueueForTesting); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return observed }
}

private struct StopRefused: Error {}

@Test("The abort path finishes both partial tracks on the capture queue, and keeps them (F632)")
func abortPathFinishesTracksOnCaptureQueue() async throws {
    let directory = try sessionDirectory("abortqueue")
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AudioCaptureEngine(
        stoppingCapture: { throw StopRefused() },
        finishingTracks: {},
        preservingPartialTracks: nil,
        startingCapture: { _, _, _ in },
        directory: directory
    )
    let probe = QueueProbe()
    try engine.beginTestTrackSession(in: directory, deviceSync: { _ in probe.record() })
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)

    await #expect(throws: StopRefused.self) { _ = try await engine.stop() }

    #expect(probe.values == [true, true], "each finish() flush must run on captureQueue")
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        let size = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path
        )[.size] as? Int
        #expect(size == 48_000 * MemoryLayout<Float>.size, "\(name) must be preserved, not cancelled")
    }
}
