import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F254 — when the capture stream died, the engine immediately gave up the power assertion that was
// the only thing keeping the Mac awake.
//
// Confirmed twice from `pmset -g log` on the user's own machine, not reasoned:
//
//   15:37:46  Notification   Display is turned off
//   15:37:46  Assertions     PID 20381(WhisperMeet) Released PreventUserIdleSystemSleep
//                            "Recording meeting audio"   (held 01:03:01)
//   15:37:51  Sleep          Entering Sleep state due to 'Clamshell Sleep'
//
//   14:00:54  Display is turned off / Released (held 01:02:15) / 14:00:59 'Clamshell Sleep'
//
// The lid closes, the display goes away, the display-bound `SCStream` dies with it, and in the SAME
// second `stream(_:didStopWithError:)` calls `endRecordingActivity()`. Five seconds later the Mac
// sleeps. The reason string is `AudioCaptureEngine`'s own "Recording meeting audio".
//
// So the app's response to losing its capture was to remove the one thing that would have kept the
// machine awake long enough to do anything about it — before a single byte was finalized. Both
// recordings were ~63 minutes into a meeting still in progress.
//
// The assertion must outlive a stream failure. It is released where it always was, in `reset()`,
// which runs on stop and cancel — i.e. once the recording has actually been dealt with.

private struct StreamDied: Error {}

@Test("A stream failure records the error but keeps the power assertion (F254)")
func streamFailureKeepsThePowerAssertion() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F254-\(UUID().uuidString)", isDirectory: true)
    let engine = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: directory
    )

    engine.beginRecordingActivity()
    #expect(engine.isHoldingRecordingActivity, "precondition: the capture holds the assertion")

    engine.handleStreamFailure(StreamDied())

    // The whole ticket: losing the stream must not put the Mac to sleep five seconds later.
    #expect(engine.isHoldingRecordingActivity,
            "a stream failure released the assertion — the Mac would sleep before anything finalized")
    #expect(engine.hasStreamError, "the failure must still be recorded so stop() can preserve tracks")
}

@Test("Ending the activity explicitly still releases it (F254 must not leak the assertion)")
func endingTheActivityStillReleasesIt() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F254-\(UUID().uuidString)", isDirectory: true)
    let engine = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: directory
    )

    engine.beginRecordingActivity()
    engine.handleStreamFailure(StreamDied())
    engine.endRecordingActivity()

    // The counterpart risk of this fix: holding the assertion forever would stop the Mac from ever
    // idling. `reset()` (stop/cancel) is the one release point, and it must actually work.
    #expect(!engine.isHoldingRecordingActivity)
}

@Test("Beginning the activity twice does not lose track of it (F254)")
func beginningTwiceIsIdempotent() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F254-\(UUID().uuidString)", isDirectory: true)
    let engine = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: directory
    )

    engine.beginRecordingActivity()
    engine.beginRecordingActivity()
    engine.endRecordingActivity()
    #expect(!engine.isHoldingRecordingActivity,
            "a double begin must not leave an assertion that one end cannot clear")
}

// MARK: - Which display the capture is pinned to (F254, part 2)

@Test("The main display is preferred over whatever happens to be first (F254)")
func mainDisplayIsPreferred() {
    // `SCContentFilter` is built around ONE display (`AudioCaptureEngine.swift:139` took
    // `content.displays.first`), and `displays.first` is not documented to be the main display — so
    // which display a capture depended on was arbitrary. In clamshell the built-in display is the
    // one that goes away, so pinning to the main display is what gives a docked Mac a chance of
    // surviving a lid close at all.
    #expect(AudioCaptureEngine.preferredDisplayIndex(displayIDs: [7, 1, 9], mainDisplayID: 1) == 1)
    #expect(AudioCaptureEngine.preferredDisplayIndex(displayIDs: [1, 7], mainDisplayID: 1) == 0)
}

@Test("An unknown main display falls back to the first, never to nothing (F254)")
func unknownMainDisplayFallsBack() {
    // Better an arbitrary display than refusing to record: `noDisplayAvailable` aborts the capture.
    #expect(AudioCaptureEngine.preferredDisplayIndex(displayIDs: [7, 9], mainDisplayID: 1) == 0)
}

@Test("No displays at all yields nil rather than an index (F254)")
func noDisplaysYieldsNil() {
    #expect(AudioCaptureEngine.preferredDisplayIndex(displayIDs: [], mainDisplayID: 1) == nil)
}

// MARK: - F276: syncing the raw tracks, once the cost was actually measured

@Test("The sync cadence is about five seconds of audio (F276)")
func trackSyncCadence() {
    // Measured on this machine rather than assumed — which is the point, because the assumption was
    // wrong. `F_FULLFSYNC` after ~960 KB (5 s of 48 kHz float32): median 3.32 ms, p99 7.42 ms idle;
    // median 3.45 ms, p99 10.55 ms with a concurrent 3 GB write. F259 declined this fix on the
    // belief that it cost "tens to hundreds of milliseconds" and would stall the
    // `sampleHandlerQueue` into dropping audio buffers. At ~10 ms every five seconds it does not.
    #expect(AudioCaptureEngine.trackSyncIntervalBytes == 48_000 * 4 * 5)
    #expect(!AudioCaptureEngine.shouldSyncTrack(bytesSinceSync: 0))
    #expect(!AudioCaptureEngine.shouldSyncTrack(bytesSinceSync: AudioCaptureEngine.trackSyncIntervalBytes - 1))
    #expect(AudioCaptureEngine.shouldSyncTrack(bytesSinceSync: AudioCaptureEngine.trackSyncIntervalBytes))
    #expect(AudioCaptureEngine.shouldSyncTrack(bytesSinceSync: AudioCaptureEngine.trackSyncIntervalBytes * 3))
}
