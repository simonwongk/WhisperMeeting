import Foundation
import Testing
@testable import WhisperCore

// F275 — a capture whose `SCStream` died stayed dead. The health monitor painted a banner within
// ~4 s, but nothing rebuilt the filter, restarted the stream, or finalized what had been captured;
// the recording only ended when the user pressed Stop. Two of the user's 21 recordings ended that
// way — a lid close killed the display-bound stream ~63 minutes into a meeting that kept going.
//
// These tests pin the decision, which is the part that can be pinned without a display, a
// microphone, or a real sleep. The physical runs the ticket also asks for — close the lid docked and
// undocked — need the user's hardware and are not claimed here.
//
// The rule the ticket settled, and why each half is not the other:
//
//  - **Never splice.** Resuming into the same `.f32` tracks with no padding shifts every later
//    timestamp by the gap, and shifts it *invisibly*: the file plays, the numbers are
//    self-consistent, nothing says the timeline moved. That is F151 by design rather than accident.
//  - **Pad a short gap with silence.** The gap is knowable from wall clock, so zero frames restore
//    `sample offset == elapsed time`. Not a fabrication: nothing was captured while the lid was
//    shut, so silence is the truth about that interval — the opposite of F256's refusal to invent
//    audio for a region it failed to *read*.
//  - **Finalize a long one**, because ten hours of zero frames is gigabytes of nothing.

private let minute: TimeInterval = 60

@Test("A dead stream mid-recording is restarted, padding the gap it missed (F275)")
func deadStreamIsRestartedWithPadding() {
    let action = CaptureRestartPolicy.action(
        trigger: .streamFailed,
        state: .recording,
        streamIsAlive: false,
        gap: 3,
        restartTimestamps: [],
        now: 0
    )
    #expect(action == .restart(padding: 3))
}

@Test("A gap past the cap finalizes instead of padding (F275)")
func longGapFinalizes() {
    let action = CaptureRestartPolicy.action(
        trigger: .didWake,
        state: .recording,
        streamIsAlive: false,
        gap: CaptureRestartPolicy.defaultMaximumPaddedGap + 1,
        restartTimestamps: [],
        now: 0
    )
    #expect(action == .finalize)
}

@Test("A gap exactly at the cap is still padded (F275)")
func gapAtTheCapIsPadded() {
    let cap = CaptureRestartPolicy.defaultMaximumPaddedGap
    let action = CaptureRestartPolicy.action(
        trigger: .didWake,
        state: .recording,
        streamIsAlive: false,
        gap: cap,
        restartTimestamps: [],
        now: 0
    )
    #expect(action == .restart(padding: cap))
}

@Test("A display change that did not kill the stream is left alone (F275)")
func liveStreamIsNotRestarted() {
    // Plugging in a second monitor reconfigures the displays without touching a capture pinned to
    // the main one. Restarting a working stream would drop audio to fix nothing.
    for trigger in CaptureRestartPolicy.Trigger.allCases {
        let action = CaptureRestartPolicy.action(
            trigger: trigger,
            state: .recording,
            streamIsAlive: true,
            gap: 0,
            restartTimestamps: [],
            now: 0
        )
        #expect(action == .none, "restarted a live stream on \(trigger)")
    }
}

@Test("Only a running recording is restarted (F275)")
func onlyARunningRecordingIsTouched() {
    // Same reasoning as `RecordingSleepPolicy`: `.starting` would race the setup, `.stopping`
    // already owns a finalize and a second would race it (the F139 hazard), and `.idle` has
    // nothing. The leftover folder is startup recovery's job, which exists for exactly this.
    for state in RecordingSleepPolicy.State.allCases where state != .recording {
        let action = CaptureRestartPolicy.action(
            trigger: .streamFailed,
            state: state,
            streamIsAlive: false,
            gap: 1,
            restartTimestamps: [],
            now: 0
        )
        #expect(action == .none, "acted on a recording in state \(state)")
    }
}

@Test("Exhausted retries within the flapping window finalize the recording rather than abandoning it (F275, F531)")
func exhaustedRetriesFinalize() {
    // "Bound the retries" must not mean "leave the capture dead and the audio unsaved" — that is
    // the state this ticket exists to end. A display that is gone for good stops the spinning by
    // saving what was captured. All three restarts sit well inside the flapping window, so this is
    // a genuine burst — F531's `restartsWithinTheWindowOnlyCount` below is what pins the OTHER half,
    // that restarts spread outside the window do not.
    let now: TimeInterval = 10_000
    let threeRecentRestarts = [now - 30, now - 20, now - 10]
    let action = CaptureRestartPolicy.action(
        trigger: .streamFailed,
        state: .recording,
        streamIsAlive: false,
        gap: 1,
        restartTimestamps: threeRecentRestarts,
        now: now
    )
    #expect(action == .finalize)

    let lastAllowed = CaptureRestartPolicy.action(
        trigger: .streamFailed,
        state: .recording,
        streamIsAlive: false,
        gap: 1,
        restartTimestamps: Array(threeRecentRestarts.dropLast()),
        now: now
    )
    #expect(lastAllowed == .restart(padding: 1))
}

// F531 — the bound used to count every restart for the whole recording, so a long meeting's 4th
// UNRELATED stream death ended it even though each restart worked and the stream stayed healthy for
// hours in between. It is now a burst: only restarts within `defaultRestartFlappingWindow` count.
@Test("Restarts outside the flapping window do not count toward the bound (F531)")
func restartsOutsideTheWindowDoNotCount() {
    // Three restarts, each hours apart — a docked MacBook's display blipping at 0:50, 2:10 and 3:40
    // into a 6-hour all-hands, each one recovering and staying healthy for hours before the next.
    let hour: TimeInterval = 3_600
    let now: TimeInterval = 4 * hour + 30 * 60  // 4:30 in
    let threeRestartsHoursApart: [TimeInterval] = [50 * 60, 2 * hour + 10 * 60, 3 * hour + 40 * 60]
    #expect(threeRestartsHoursApart.count == CaptureRestartPolicy.defaultMaximumRestarts)

    // A 4th, unrelated blip at 4:30 must still be allowed to restart — none of the first three is
    // within the window of `now`.
    let action = CaptureRestartPolicy.action(
        trigger: .displayReconfigured,
        state: .recording,
        streamIsAlive: false,
        gap: 2,
        restartTimestamps: threeRestartsHoursApart,
        now: now
    )
    #expect(action == .restart(padding: 2), "3 restarts spread over hours finalized an unrelated 4th")

    // But a burst of 3 packed into the last few minutes before this 4th one DOES finalize — the
    // window itself still bounds a genuinely flapping stream.
    let packedBurst: [TimeInterval] = [now - 500, now - 300, now - 100]
    let finalizes = CaptureRestartPolicy.action(
        trigger: .displayReconfigured,
        state: .recording,
        streamIsAlive: false,
        gap: 2,
        restartTimestamps: packedBurst,
        now: now
    )
    #expect(finalizes == .finalize, "a genuine burst within the window must still finalize")
}

@Test("The flapping window is derived from the padded-gap cap already in this file, not a fresh guess (F531)")
func flappingWindowIsDerivedFromTheGapCap() {
    #expect(CaptureRestartPolicy.defaultRestartFlappingWindow == 2 * CaptureRestartPolicy.defaultMaximumPaddedGap)
    #expect(CaptureRestartPolicy.defaultRestartFlappingWindow == 10 * minute)
}

@Test("A restart exactly at the edge of the window still counts; just past it does not (F531)")
func restartAtTheWindowEdge() {
    let now: TimeInterval = 1_000
    let window = CaptureRestartPolicy.defaultRestartFlappingWindow

    // Two restarts already in the window, one exactly at the edge (still counts) makes 3: finalize.
    let atEdge = CaptureRestartPolicy.action(
        trigger: .streamFailed, state: .recording, streamIsAlive: false, gap: 1,
        restartTimestamps: [now - 1, now - 2, now - window], now: now
    )
    #expect(atEdge == .finalize)

    // The same shape, but the oldest is one second past the edge: only 2 remain in the window.
    let justPast = CaptureRestartPolicy.action(
        trigger: .streamFailed, state: .recording, streamIsAlive: false, gap: 1,
        restartTimestamps: [now - 1, now - 2, now - window - 1], now: now
    )
    #expect(justPast == .restart(padding: 1))
}

@Test("A backwards clock pads nothing rather than a negative span (F275)")
func backwardsClockIsClamped() {
    // The gap is wall-clock arithmetic, and wall clock can move backwards (NTP correction across a
    // sleep is the realistic case). A negative padding would be a negative frame count.
    let action = CaptureRestartPolicy.action(
        trigger: .didWake,
        state: .recording,
        streamIsAlive: false,
        gap: -30,
        restartTimestamps: [],
        now: 0
    )
    #expect(action == .restart(padding: 0))
}

@Test("The padding cap is stated in both minutes and the disk it costs (F275)")
func capIsDocumentedInBytes() {
    // The cap exists to bound *disk*, not to express an opinion about meetings: two raw float32
    // tracks at 48 kHz cost 384 KB for every second of silence written.
    #expect(CaptureRestartPolicy.defaultMaximumPaddedGap == 5 * minute)
    #expect(CaptureRestartPolicy.paddingByteCount(forGap: 1, sampleRate: 48_000) == 48_000 * 4 * 2)
    #expect(CaptureRestartPolicy.paddingByteCount(
        forGap: CaptureRestartPolicy.defaultMaximumPaddedGap,
        sampleRate: 48_000
    ) == 115_200_000)
}

@Test("A padded gap is a frame count both tracks agree on (F275)")
func paddingConvertsToWholeFrames() {
    #expect(CaptureRestartPolicy.paddingFrames(forGap: 1, sampleRate: 48_000) == 48_000)
    #expect(CaptureRestartPolicy.paddingFrames(forGap: 0, sampleRate: 48_000) == 0)
    // Rounded, not truncated, and identically for both tracks — a half-frame disagreement between
    // microphone and system audio is a permanent channel offset for the rest of the meeting.
    #expect(CaptureRestartPolicy.paddingFrames(forGap: 0.000_010_5, sampleRate: 48_000) == 1)
}

@Test("A restart is never silent — the user is told which happened (F275)")
func everyOutcomeHasANotice() {
    // "Never restart silently" is an invariant, not copy polish: the transcript's timestamps depend
    // on whether the recording is continuous, so a user who cannot tell has no way to read them.
    let padded = CaptureRestartPolicy.notice(for: .restart(padding: 92), trigger: .didWake)
    #expect(padded?.contains("1 min 32 sec") == true)
    #expect(padded?.contains("silence") == true)

    let finalized = CaptureRestartPolicy.notice(for: .finalize, trigger: .streamFailed)
    #expect(finalized?.isEmpty == false)
    #expect(CaptureRestartPolicy.notice(for: .none, trigger: .displayReconfigured) == nil)
}

@Test("A padded resume is its own alignment, not a clean capture or a rebuild (F275)")
func paddedResumeHasItsOwnAlignment() {
    // `SourceTrackManifest` already separates "captured-timeline" from
    // "zero-aligned-after-interruption". A padded resume is neither, and recording it as either
    // would make the manifest lie about which timeline a consumer is reading.
    #expect(CaptureRestartPolicy.paddedAlignment == "padded-after-restart")
    #expect(CaptureRestartPolicy.paddedAlignment != "captured-timeline")
    #expect(CaptureRestartPolicy.paddedAlignment != "zero-aligned-after-interruption")
}

@Test("An absurd gap saturates rather than trapping (F151's lesson, applied here)")
func paddingFramesSaturates() {
    // The identical defect F151's self-review found one function over: `Int64(Double)` TRAPS on
    // overflow in Swift, and 1e18 is finite. Today's only caller bounds `gap` to
    // `defaultMaximumPaddedGap` before reaching here, so the live path cannot hit it — but this is
    // `public`, and a conversion that crashes on a plausible argument is a defect whatever its
    // current callers happen to do.
    //
    // Saturating rather than clamping to the policy cap: this function converts, it does not
    // decide. `action(…)` owns the cap, and a caller deliberately asking about a longer span should
    // get the largest representable answer instead of a crash.
    #expect(CaptureRestartPolicy.paddingFrames(forGap: 1e18, sampleRate: 48_000) == Int64.max)
    #expect(CaptureRestartPolicy.paddingFrames(forGap: .infinity, sampleRate: 48_000) == Int64.max)
    #expect(CaptureRestartPolicy.paddingFrames(forGap: .nan, sampleRate: 48_000) == 0)
    // And the ordinary values are unchanged.
    #expect(CaptureRestartPolicy.paddingFrames(forGap: 1, sampleRate: 48_000) == 48_000)
}

@Test("The disk figure saturates too, rather than overflowing the multiply (F151's lesson)")
func paddingByteCountSaturates() {
    // `frames * 4 * 2` overflows `Int64` for a saturated frame count, and `*` traps in Swift.
    #expect(CaptureRestartPolicy.paddingByteCount(forGap: 1e18, sampleRate: 48_000) == Int64.max)
    #expect(CaptureRestartPolicy.paddingByteCount(forGap: 1, sampleRate: 48_000) == 48_000 * 4 * 2)
}

@Test("A gap under a second is described as such, not as '0 sec' (F292 rerun)")
func subSecondGapIsDescribedPlainly() {
    // The rerun's real gap was 0.39 s, and the notice read "The 0 sec that could not be captured".
    let notice = CaptureRestartPolicy.notice(for: .restart(padding: 0.39), trigger: .streamFailed)
    #expect(notice?.contains("0 sec") == false)
    #expect(notice?.contains("under a second") == true)
    #expect(CaptureRestartPolicy.notice(for: .restart(padding: 12), trigger: .streamFailed)?.contains("12 sec") == true)
}
