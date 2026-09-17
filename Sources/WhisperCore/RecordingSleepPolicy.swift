import Foundation

/// What a recording should do when the Mac is about to sleep, or has just woken (F253).
///
/// Nothing reacted to either event before this: a capture alive when the machine slept simply
/// ended, and the meeting had to be rebuilt from its raw tracks on the next launch as
/// "Recovered Meeting <date>" instead of being saved as itself, with its title and markers.
///
/// **What this does and does not cover, after F254.** The two interruptions actually observed on the
/// user's machine were lid closes, where the display-bound `SCStream` dies *before* the system
/// sleeps — so a sleep handler would not have saved those. It covers the other sleep paths, where
/// the stream is still alive when macOS posts `willSleep` and waits a few seconds before
/// suspending: Apple menu ▸ Sleep, a forced low-battery sleep, and a clamshell sleep on a machine
/// whose capture survived the display going away. That window is enough to finalize.
///
/// Re-arming the stream on wake is deliberately absent — that is **F275**, shared with F254's
/// display-reconfiguration restart, and it carries the pad-versus-finalize decision that must not be
/// made by default.
///
/// A pure transition table so the decisions are pinned without a Mac, a display, or a real sleep.
public enum RecordingSleepPolicy {

    /// The recording lifecycle, mirroring `AppModel.RecordingState` without its payloads.
    ///
    /// Deliberately a separate type: this belongs in `WhisperCore`, which cannot see `AppModel`, and
    /// the policy depends only on *which* phase a recording is in, never on when it started.
    public enum State: CaseIterable, Sendable, Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    public enum Event: Sendable, Equatable {
        case willSleep
        case didWake
    }

    public enum Action: Sendable, Equatable {
        /// Do nothing.
        case none
        /// Stop and save the recording now, while the system is still awake.
        case finalize
    }

    /// The action for a lifecycle phase and a power event.
    public static func action(for state: State, on event: Event) -> Action {
        switch event {
        case .didWake:
            // Nothing until F275 decides whether a resumed capture pads the gap with silence or
            // finalizes and starts a new segment. Resuming into the same `.f32` tracks would
            // butt-splice an unrecorded gap and silently shift every later timestamp (F151).
            return .none
        case .willSleep:
            switch state {
            case .recording:
                return .finalize
            case .stopping:
                // A stop is already running and owns the finalize; a second would race it — the
                // hazard F139 closed for Cancel-during-stop. macOS can also post `willSleep` more
                // than once around a failed sleep attempt, and this is what makes that idempotent:
                // the first finalize moves the state to `.stopping`, which is a no-op.
                return .none
            case .starting:
                // Capture is still being set up, so there is nothing finalizable and interrupting
                // would race the setup. The folder is left for startup recovery, which exists for
                // exactly this.
                return .none
            case .idle:
                return .none
            }
        }
    }
}
