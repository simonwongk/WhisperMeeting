import Foundation

/// What a recording should do when its capture stream has died and might be revivable (F275).
///
/// Before this, a dead `SCStream` simply stayed dead. `RecordingHealthMonitor` noticed within ~4 s
/// and the window painted a red banner, but nothing rebuilt the content filter, restarted the
/// stream, or finalized what had already been captured — the recording ended only when the user
/// pressed Stop. Two of the user's 21 recordings ended that way: a lid close killed the
/// display-bound stream ~63 minutes into a meeting that kept going, and none of the rest was
/// captured. See F254 for the `pmset -g log` chain that established it was a lid close and not a
/// quit or a crash.
///
/// **Three decisions, and why each is what it is.**
///
/// *Never splice.* Resuming into the same `.f32` tracks without padding makes every timestamp after
/// the gap wrong by the gap's duration, and wrong **invisibly**: the file plays, the numbers are
/// self-consistent, and nothing anywhere says the timeline moved. Every consumer of those tracks —
/// markers, the forced aligner, transcript seeking — reads sample offset as elapsed time. It is also
/// exactly the defect **F151** documents, so splicing would reintroduce a known bug deliberately.
///
/// *Pad a short gap with real silence.* The gap is knowable from wall clock, so writing that many
/// zero frames into both tracks restores `sample offset == elapsed time` and keeps the meeting
/// whole. This is not the fabrication **F256** refuses: F256 declines to invent audio for a region
/// it failed to *read*, because that audio existed and silence would assert something false about
/// it. Here nothing was captured while the lid was shut, so silence is the truth about the interval.
/// Same bytes, opposite epistemics — worth stating because the two positions look contradictory.
///
/// *Finalize a long one.* Ten hours of zero frames is gigabytes of nothing.
///
/// A pure decision table, so the transitions are pinned without a display, a microphone, or a real
/// sleep — the shape `RecordingSleepPolicy` took, and for the same reason.
public enum CaptureRestartPolicy {

    /// What prompted the check. Recorded in the notice and the log, and **not** an input to the
    /// decision: every way a trigger could matter reaches the rule through `gap` and `streamIsAlive`
    /// instead. Taking it as a parameter that changed the outcome would imply a distinction the
    /// code does not make.
    public enum Trigger: CaseIterable, Sendable, Equatable {
        /// `stream(_:didStopWithError:)` fired.
        case streamFailed
        /// The display set changed — the pinned display may have gone away (F254).
        case displayReconfigured
        /// `NSWorkspace.didWakeNotification`; the gap is how long the Mac slept.
        case didWake
    }

    public enum Action: Sendable, Equatable {
        /// Nothing to do — the stream is alive, or there is no recording to act on.
        case none
        /// Restart the capture, first writing `padding` seconds of silence into both tracks.
        case restart(padding: TimeInterval)
        /// Stop and save what was captured; the gap is too long, or the retries are spent.
        case finalize
    }

    /// How long a gap may be and still be padded rather than ending the meeting.
    ///
    /// **This default is a judgement and the user's to change.** The threshold governs a *product*
    /// question — is this still one meeting? — not a correctness inference, which is why a threshold
    /// is acceptable here when one was refused elsewhere. Being wrong either way is benign: an extra
    /// meeting, or a little more silence. Neither corrupts a timeline.
    ///
    /// Five minutes is chosen from the disk cost rather than from a theory of meetings, because that
    /// is the part with a number in it: two raw float32 tracks at 48 kHz cost **384 KB per second**
    /// of silence, so five minutes is ~115 MB and an overnight lid close would be ~14 GB. A coffee
    /// break stays one meeting; a night does not.
    public static let defaultMaximumPaddedGap: TimeInterval = 5 * 60

    /// How many restarts one recording may attempt before it is saved instead.
    public static let defaultMaximumRestarts = 3

    /// The manifest's `recoveryAlignment` for a recording that was padded and resumed.
    ///
    /// Its own value on purpose. `SourceTrackManifest` already separates `"captured-timeline"` from
    /// `"zero-aligned-after-interruption"`, and a padded resume is neither a clean capture nor a
    /// zero-aligned rebuild; recording it as either would make the manifest misdescribe the timeline
    /// a consumer is reading.
    public static let paddedAlignment = "padded-after-restart"

    /// The action for a trigger, a lifecycle phase, and a gap.
    public static func action(
        trigger: Trigger,
        state: RecordingSleepPolicy.State,
        streamIsAlive: Bool,
        gap: TimeInterval,
        restartsSoFar: Int,
        maximumPaddedGap: TimeInterval = CaptureRestartPolicy.defaultMaximumPaddedGap,
        maximumRestarts: Int = CaptureRestartPolicy.defaultMaximumRestarts
    ) -> Action {
        // Only a running recording. `.starting` would race the setup, `.stopping` already owns a
        // finalize and a second would race it (the hazard F139 closed for Cancel-during-stop), and
        // `.idle` has nothing. A folder left behind is startup recovery's job.
        guard state == .recording else { return .none }
        // A display change that did not kill the capture needs no repair — plugging in a second
        // monitor reconfigures the displays without touching a stream pinned to the main one, and
        // restarting a working stream would drop audio to fix nothing.
        guard !streamIsAlive else { return .none }
        // Bounded, but bounded into `.finalize`, never into abandonment: leaving the capture dead
        // and the audio unsaved is the state this ticket exists to end.
        guard restartsSoFar < maximumRestarts else { return .finalize }
        // Clamped, because this is wall-clock arithmetic and wall clock moves backwards — an NTP
        // correction across a sleep is the realistic case. A negative padding is a negative frame
        // count.
        let padding = max(0, gap)
        return padding <= maximumPaddedGap ? .restart(padding: padding) : .finalize
    }

    /// Frames of silence to write into **each** track for a gap of `gap` seconds.
    ///
    /// Rounded rather than truncated, and by one function rather than per track: a half-frame
    /// disagreement between microphone and system audio is a permanent channel offset for the rest
    /// of the meeting.
    public static func paddingFrames(forGap gap: TimeInterval, sampleRate: Double) -> Int64 {
        guard gap > 0, sampleRate > 0 else { return 0 }
        return saturatingFrames(gap * sampleRate)
    }

    /// `Double` → `Int64`, saturating instead of trapping.
    ///
    /// `Int64(Double)` **traps** on overflow in Swift rather than saturating, and `isFinite` does
    /// not protect against it — 1e18 is finite and 1e18 × 48000 is far past `Int64.max`. Today's
    /// only caller bounds the gap to `defaultMaximumPaddedGap` first, so the live path cannot reach
    /// it, but these are `public` and a conversion that crashes on a plausible argument is a defect
    /// whatever its current callers happen to do. Found by self-review after the identical trap in
    /// `CaptureGapPolicy` was observed crashing a test with signal 5.
    ///
    /// Saturating rather than clamping to the policy's cap, because this converts and does not
    /// decide: `action(…)` owns the cap, and a caller deliberately asking about a longer span
    /// should get the largest representable answer rather than a crash. NaN yields 0, since it
    /// fails the comparison below.
    public static func saturatingFrames(_ value: Double) -> Int64 {
        guard value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return .max }
        return Int64(value.rounded())
    }

    /// Bytes the padding costs on disk, across both raw float32 tracks.
    ///
    /// Exists so the cap can be reasoned about in the unit that actually constrains it. The cap is
    /// about disk, and a threshold in minutes hides that.
    public static func paddingByteCount(forGap gap: TimeInterval, sampleRate: Double) -> Int64 {
        // `multipliedReportingOverflow`, because `*` traps too: a saturated frame count times 8
        // overflows `Int64`, so the guard above would have moved the crash one line down.
        let frames = paddingFrames(forGap: gap, sampleRate: sampleRate)
        let (bytes, overflowed) = frames.multipliedReportingOverflow(
            by: Int64(MemoryLayout<Float>.size) * 2
        )
        return overflowed ? .max : bytes
    }

    /// What to tell the user, or nil when nothing happened.
    ///
    /// **Never restart silently** is an invariant rather than copy polish: the transcript's
    /// timestamps mean different things depending on whether the recording is continuous, so a user
    /// who cannot tell a continuous recording from a stitched one has no way to read them.
    public static func notice(for action: Action, trigger: Trigger) -> String? {
        switch action {
        case .none:
            return nil
        case let .restart(padding):
            return """
            Recording resumed after \(trigger.phrase). \
            The \(durationPhrase(padding)) that could not be captured is silence in the audio, \
            so the timestamps after it still line up with the clock.
            """
        case .finalize:
            return """
            Recording stopped and saved after \(trigger.phrase). \
            Everything captured up to that point is kept; anything said afterwards was not recorded.
            """
        }
    }

    /// "1 min 32 sec" — coarse on purpose, since the number is a description of a hole in the audio
    /// rather than a measurement the user can act on to more precision than this.
    static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total) sec" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }
}

private extension CaptureRestartPolicy.Trigger {
    /// Plain language, because this lands in a user-facing sentence. No `SCStream`, no "content
    /// filter" — what the user did is close a lid or unplug a monitor.
    var phrase: String {
        switch self {
        case .streamFailed:
            return "the audio capture stopped unexpectedly"
        case .displayReconfigured:
            return "a display was disconnected"
        case .didWake:
            return "this Mac woke from sleep"
        }
    }
}
