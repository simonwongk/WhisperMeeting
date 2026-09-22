import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F365 — Stop's bounded wait was a fall-through, not a decision.
//
// `waitForCaptureRestartToSettle` returned nothing and both callers proceeded to `stop()`/`cancel()`
// either way, so a restart that outlived the 10 s bound ran in parallel with the finalize. That is
// not a hypothetical margin: `restartAfterFailure` awaits `SCShareableContent.excludingDesktop
// Windows`, the call `AudioCaptureEngine` logs separately because it is slow — and slowest exactly
// when displays are in flux, which is the only time a restart happens at all.
//
// Three things were reachable in that window, worst first: an unsynchronized load/store of a
// strong `FloatTrackWriter` reference, which can over-release and abort; a write into a descriptor
// `finish()` had already closed, which `FloatTrackFile.swift:150-151` warns "in the worst case has
// already been reused by another open file"; and a `paddedGaps` array appended from two threads,
// which reaches F282's end state through a race instead of through a lost field.
//
// The bound is 200 × 50 ms in production. These tests shorten it through
// `captureRestartSettleTicksForTesting` rather than waiting ten seconds — the behaviour under test
// is what happens when it EXPIRES, and the number it expires at is not the thing being checked.

/// A restart that will not finish until the test says so.
///
/// **Polling, not a semaphore, and the first version of this file proved why.** The restart seam is
/// `async` and `handleCaptureInterruption` is `@MainActor`, so a `DispatchSemaphore.wait()` on
/// either side blocks a thread something else needs: waiting on the main actor stops the very task
/// that would signal it, and blocking in the seam occupies a cooperative-pool thread the suite
/// then starves on. That deadlock is F115's and F169's shape and it wedged the run for two
/// minutes before this was rewritten. Every wait here yields.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var _released = false

    var entered: Bool { lock.withLock { _entered } }
    private var released: Bool { lock.withLock { _released } }

    /// Called from the restart seam: announces arrival, then waits for `release()`.
    func blockUntilReleased() async {
        lock.withLock { _entered = true }
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func waitUntilEntered() async {
        for _ in 0..<2_000 where !entered { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { lock.withLock { _released = true } }
}

/// A `@Sendable` slot, for the two places a closure has to see something built after it.
private final class Slot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    var current: Value? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
private func makeModel(
    restart: @escaping @Sendable (Int64) async throws -> Void,
    finishingTracks: @escaping () throws -> Void = {}
) throws -> (AppModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StopUnderHungRestart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F365.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let recorder = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: finishingTracks,
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: restart,
        directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: recorder,
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    // Two ticks rather than two hundred: the expiry is the behaviour, not the duration.
    model.captureRestartSettleTicksForTesting = 2
    return (model, root, defaults, suite)
}

@MainActor
@Test("A restart that outlives Stop's wait is cancelled, not left running beside the finalize (F365)")
func aHungRestartIsCancelledByStop() async throws {
    let gate = Gate()
    // `finishingTracks` runs INSIDE `stop()`, immediately before the writers are finished — the
    // one moment where "was the restart invalidated in time?" has an answer. Reading the
    // generation there is what makes this test fail without the fix: `reset()` bumps it too, but
    // only afterwards, so a fall-through Stop reaches the finalize with the restart still live.
    let engine = Slot<AudioCaptureEngine>()
    let generationAtFinalize = Slot<Int>()
    let (model, root, defaults, suite) = try makeModel(
        restart: { _ in await gate.blockUntilReleased() },
        finishingTracks: { generationAtFinalize.current = engine.current?.sessionGenerationForTesting }
    )
    engine.current = model.recorder
    defer {
        gate.release()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    // Real track writers with five seconds in them, so `stop()` finalizes a real recording rather
    // than throwing `noAudioCaptured` — the ticket's Verification is about what the finalize
    // produces, which needs there to be one.
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(
        system: 48_000 * 5, microphone: 48_000 * 5, systemStart: 0, microphoneStart: 0
    )
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    // Start the restart and let it reach the gate, where it stays.
    let restarting = Task { await model.handleCaptureInterruption(trigger: .streamFailed, gap: 1, now: Date()) }
    await gate.waitUntilEntered()
    try #require(model.isRestartingCapture, "the fixture must actually be mid-restart")
    try #require(model.recorder.pendingRestartPaddingForTesting > 0, "a second of silence is owed")
    let generationBefore = model.recorder.sessionGenerationForTesting

    await model.stopRecording(title: "hung restart")

    // **The assertion this ticket turns on.** The generation had already moved by the time the
    // finalize began, so the restart's next `ensureSession` throws and it cannot write into
    // writers `stop()` is closing. Asserting it only at the end would pass without the fix, since
    // `reset()` bumps the generation as well — a whole finalize later.
    let atFinalize = try #require(generationAtFinalize.current, "the finalize never ran")
    #expect(atFinalize > generationBefore,
            "the restart was still live while the tracks were being finished (\(atFinalize) vs \(generationBefore))")
    #expect(model.recordingState == .idle)
    let saved = try #require(model.store.meetings.first { $0.id == id }, "the recording must still be saved")

    // The ticket's Verification, in the only form the timeline can express it: the owed second of
    // silence was NOT paid, because the restart that owed it was cancelled. Five seconds in, five
    // seconds out. "Did not crash" would see none of this.
    #expect(abs(saved.duration - 5) < 0.2, "duration \(saved.duration) — padding leaked into a finished track")

    gate.release()
    await restarting.value
    // And the cancelled restart, once it unblocks, resurrects nothing: it publishes no stream into
    // an engine that has been reset, which is the failure the generation counter exists for.
    #expect(!model.recorder.hasLiveStreamForTesting)
    #expect(model.recorder.pendingRestartPaddingForTesting == 0)
}

@MainActor
@Test("A restart that owed padding pays none of it once it is cancelled (F365)")
func anAbandonedRestartPaysNoPadding() async throws {
    // The manifest must describe gaps that were actually paid. A cancelled restart paid none, so
    // leaving `pendingRestartPadding` set would either put silence into a finished track or record
    // a gap that does not exist in the audio — F275's timeline-honesty rule, from the other side.
    let gate = Gate()
    // The seam does not need to owe the padding itself: `restartAfterFailure` calls
    // `setPendingRestartPadding` immediately BEFORE invoking the injected restart, so by the time
    // the gate blocks the silence is already owed. That ordering is the production one, which is
    // what makes this test about the abandon rather than about the fixture.
    let (model, root, defaults, suite) = try makeModel(restart: { _ in
        await gate.blockUntilReleased()
    })
    defer {
        gate.release()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
    let restarting = Task { await model.handleCaptureInterruption(trigger: .streamFailed, gap: 1, now: Date()) }
    await gate.waitUntilEntered()
    try #require(model.recorder.pendingRestartPaddingForTesting > 0, "the fixture must owe silence")

    #expect(model.recorder.abandonInFlightRestart(), "a restart was in flight, so it was abandoned")
    #expect(model.recorder.pendingRestartPaddingForTesting == 0, "silence owed by a cancelled restart is not owed")

    gate.release()
    await restarting.value
}

@MainActor
@Test("With no restart in flight, Stop's wait settles and cancels nothing (F365)")
func aQuietStopAbandonsNothing() async throws {
    let (model, root, defaults, suite) = try makeModel(restart: { _ in })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    await model.startRecording()
    let before = model.recorder.sessionGenerationForTesting
    #expect(!model.recorder.abandonInFlightRestart(), "nothing was in flight")
    #expect(model.recorder.sessionGenerationForTesting == before,
            "abandoning nothing must not invalidate the live session")
    await model.stopRecording(title: "quiet")
    #expect(model.recordingState == .idle)
}

@Test("Every field the padding touches is reachable only through the capture queue (F365)")
func thePaddingsFieldsAreQueueProtected() throws {
    // F334 protected `_stream` and `pendingRestartPadding`; F364 protected `_streamError` and
    // `_streamDied` after finding the doc comment had claimed it for two years. The three the
    // padding itself touches were still plain properties. Asserted against the declarations
    // rather than against a `contains` anywhere in the file — F364's own log entry records a
    // version of this guard that passed after the protection was deliberately removed, because
    // the searched text appeared elsewhere.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    for field in ["systemWriter", "microphoneWriter", "paddedGaps"] {
        #expect(source.contains("private var _\(field)"), "\(field) has no queue-backed storage")
        let accessor = try #require(source.range(of: "private var \(field): "))
        let window = source[accessor.lowerBound...].prefix(260)
        #expect(window.contains("get { captureQueue.sync { _\(field) } }"), "\(field): \(window)")
        #expect(window.contains("set { captureQueue.sync { _\(field) = newValue } }"), "\(field): \(window)")
    }
    // And `reset()` nils them inside its sync, which is where its own comment always said the
    // whole reset belonged.
    let reset = try #require(source.range(of: "private func reset() {"))
    let body = source[reset.lowerBound...].prefix(1_400)
    let sync = try #require(body.range(of: "captureQueue.sync {"))
    let closing = try #require(body[sync.upperBound...].range(of: "\n        }"))
    let inside = body[sync.upperBound..<closing.lowerBound]
    #expect(inside.contains("_systemWriter = nil"))
    #expect(inside.contains("_microphoneWriter = nil"))
    #expect(inside.contains("_paddedGaps = []"))
}

@Test("The restart pays its padding under the same generation check, not after one (F365)")
func thePaddingIsPaidInsideTheGenerationCheck() throws {
    // A check-then-act is what this was: `try ensureSession(generation)` on one line and
    // `captureQueue.sync { try applyPendingRestartPaddingIfNeeded() }` on the next, with a stop
    // free to land between them. Now one critical section.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let call = try #require(source.range(of: "try applyPendingRestartPaddingIfNeeded()\n            }"))
    let window = source[source.index(call.lowerBound, offsetBy: -220)..<call.upperBound]
    #expect(window.contains("guard generation == _sessionGeneration else { throw CancellationError() }"),
            "\(window)")
}
