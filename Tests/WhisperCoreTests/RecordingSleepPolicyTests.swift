import Foundation
import Testing
@testable import WhisperCore

// F253 — nothing reacted to the Mac going to sleep during a recording.
//
// `grep -rn "willSleepNotification\|didWakeNotification" Sources/` returned nothing, so a capture
// that was alive when the machine slept simply ended, and the meeting had to be rebuilt from raw
// tracks on the next launch as "Recovered Meeting <date>" rather than saved as itself.
//
// Scope, after F254: the confirmed field failures were lid closes, where the display-bound stream
// dies *before* the system sleeps, so a sleep handler would not have saved those two. It saves the
// other sleep paths — Apple menu ▸ Sleep, a forced low-battery sleep, and `'Clamshell Sleep'` on a
// machine whose stream is still alive — where macOS posts `willSleep` and waits a few seconds
// before suspending. That window is enough to finalize.
//
// Re-arming the stream on wake is deliberately NOT here: it is F275, shared with F254's display
// reconfiguration, and it carries the pad-versus-finalize decision.
//
// This is the transition table, pinned without a Mac, a display, or a real sleep.

@Test("Sleeping mid-recording finalizes the meeting (F253)")
func sleepWhileRecordingFinalizes() {
    // The whole point: turn "lose the meeting, rebuild it next launch" into "save it now".
    #expect(RecordingSleepPolicy.action(for: .recording, on: .willSleep) == .finalize)
}

@Test("Sleeping while already stopping does nothing, so a stop cannot be finalized twice (F253)")
func sleepWhileStoppingIsIgnored() {
    // `stopRecording` is already running and owns the finalize. A second one would race it — the
    // same hazard F139 closed for Cancel-during-stop, which is why cancel is refused in `.stopping`.
    #expect(RecordingSleepPolicy.action(for: .stopping, on: .willSleep) == .none)
}

@Test("Sleeping while starting does nothing, because there is nothing finalizable yet (F253)")
func sleepWhileStartingIsIgnored() {
    // Capture is still being set up; there is no artifact to finalize and interrupting the setup
    // would race it. The folder is left for startup recovery, which is what it is for.
    #expect(RecordingSleepPolicy.action(for: .starting, on: .willSleep) == .none)
}

@Test("Sleeping while idle does nothing (F253)")
func sleepWhileIdleIsIgnored() {
    #expect(RecordingSleepPolicy.action(for: .idle, on: .willSleep) == .none)
}

@Test("Waking never acts on its own — restarting the stream is F275 (F253)")
func wakeDoesNothingYet() {
    // Asserted rather than left unsaid, so a future change to this table is a deliberate one:
    // resuming into the same tracks would butt-splice an unrecorded gap (F151), and choosing
    // between padding and finalizing is F275's decision.
    for state in RecordingSleepPolicy.State.allCases {
        #expect(RecordingSleepPolicy.action(for: state, on: .didWake) == .none,
                "wake must not act while F275 is unresolved (state: \(state))")
    }
}

@Test("Two sleep notifications in a row finalize once, not twice (F253)")
func repeatedSleepIsIdempotentThroughState() {
    // macOS can post `willSleep` more than once around a failed sleep attempt. The guard is the
    // state machine, not a flag: after the first finalize the recording is `.stopping`, and
    // `.stopping` is a no-op.
    #expect(RecordingSleepPolicy.action(for: .recording, on: .willSleep) == .finalize)
    #expect(RecordingSleepPolicy.action(for: .stopping, on: .willSleep) == .none)
}
