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
        restartsSoFar: 0
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
        restartsSoFar: 0
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
        restartsSoFar: 0
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
            restartsSoFar: 0
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
            restartsSoFar: 0
        )
        #expect(action == .none, "acted on a recording in state \(state)")
    }
}

@Test("Exhausted retries finalize the recording rather than abandoning it (F275)")
func exhaustedRetriesFinalize() {
    // "Bound the retries" must not mean "leave the capture dead and the audio unsaved" — that is
    // the state this ticket exists to end. A display that is gone for good stops the spinning by
    // saving what was captured.
    let action = CaptureRestartPolicy.action(
        trigger: .streamFailed,
        state: .recording,
        streamIsAlive: false,
        gap: 1,
        restartsSoFar: CaptureRestartPolicy.defaultMaximumRestarts
    )
    #expect(action == .finalize)

    let lastAllowed = CaptureRestartPolicy.action(
        trigger: .streamFailed,
        state: .recording,
        streamIsAlive: false,
        gap: 1,
        restartsSoFar: CaptureRestartPolicy.defaultMaximumRestarts - 1
    )
    #expect(lastAllowed == .restart(padding: 1))
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
        restartsSoFar: 0
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
