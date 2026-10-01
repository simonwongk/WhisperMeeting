import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F484 — the delegate's stale-stream guard had no test.
//
// ScreenCaptureKit reports a dead stream through `stream(_:didStopWithError:)`, and that callback
// guards on the stream being the live one: after a restart (F275) the replaced stream can still
// report its own stop, late, and that report must not mark the healthy new capture dead — the
// health tick would restart it again (`AppModel` restarts on `captureDidDie`). Every test of a
// stream reporting its own death went through `handleStreamFailure`, which has no production caller
// and skips the guard, so deleting the guard failed nothing.
//
// These drive the delegate's own body, `recordStreamStop(from:error:)`. The live stream is a
// stand-in object, not an `SCStream`: building one needs an `SCContentFilter`, whose declared
// initializers all take an `SCDisplay` or `SCWindow`. Those are init-unavailable and come only from
// `SCShareableContent`, which is behind the Screen Recording permission — a test must not ask for it.
//
// No clock. `recordStreamStop` hands its work to the serial `captureQueue` asynchronously, so each
// test calls `drainCaptureQueueForTesting()` (a `captureQueue.sync {}`) before it asserts. That
// orders the assertions after the queued block whatever `captureDidDie` and `hasStreamError` do to
// read their value. Without it, an accessor that does not wait on the queue fails the death test,
// and passes the ignore tests' expectations on it without checking anything.

private struct LateStop: Error {}

private func makeEngine() -> AudioCaptureEngine {
    AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("F484-\(UUID().uuidString)", isDirectory: true)
    )
}

@Test("A stop reported by a stream that is no longer the live one is ignored (F484)")
func staleStreamStopIsIgnored() {
    let engine = makeEngine()
    let replacedStream = NSObject()
    let liveStream = NSObject()
    engine.installLiveStreamStandInForTesting(liveStream)

    engine.recordStreamStop(from: replacedStream, error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(!engine.captureDidDie, "a late stop from a replaced stream marked the live capture dead")
    #expect(!engine.hasStreamError, "a late stop from a replaced stream recorded an error on the live capture")
}

@Test("A stop reported when there is no live stream at all is ignored (F484)")
func stopWithNoLiveStreamIsIgnored() {
    let engine = makeEngine()

    engine.recordStreamStop(from: NSObject(), error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(!engine.captureDidDie)
    #expect(!engine.hasStreamError)
}

@Test("The live stream's own stop records a death (F484)")
func liveStreamStopRecordsDeath() {
    let engine = makeEngine()
    let liveStream = NSObject()
    engine.installLiveStreamStandInForTesting(liveStream)

    engine.recordStreamStop(from: liveStream, error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(engine.captureDidDie, "the live stream stopped and the engine did not notice")
    #expect(engine.hasStreamError)
}

@Test("The SCStream delegate callback forwards to the guarded body (F484)")
func delegateForwardsToRecordStreamStop() throws {
    // The three tests above call `recordStreamStop` directly, so they cannot see a delegate that
    // stops calling it — re-inlined without the guard, say. This is the crude check that can.
    let lines = try SourceAssertion.uncommentedLines("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let declaration = try #require(
        lines.firstIndex { $0.text.contains("func stream(_ stream: SCStream, didStopWithError error: Error) {") },
        "the SCStreamDelegate stop callback was not found"
    )
    let body = lines[(declaration + 1)...]
        .map { $0.text.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    #expect(Array(body.prefix(2)) == ["recordStreamStop(from: stream, error: error)", "}"],
            "stream(_:didStopWithError:) must be exactly a forward to recordStreamStop(from:error:)")
}
