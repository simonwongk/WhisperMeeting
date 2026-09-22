import Foundation

/// `Double` → integer without trapping.
///
/// **Why this exists as shared code rather than a guard at each site.** `Int(Double)` and
/// `Int64(Double)` **trap** on overflow in Swift rather than saturating, and on 2026-09-17 that
/// defect was found five separate times in one day — F151's gap cap, F275's padding conversion,
/// `FloatTrackMixer`'s front-padding, F287's transcript formatter, and then a sweep for the shape
/// turned up five more sites. Four were found one at a time, by accident.
///
/// Every instance shared two properties worth naming:
///
/// - **`isFinite` does not help.** `1e30` is perfectly finite, and `1e30` is past `Int.max`. The
///   value that took the app down on launch came from a `meetings.json` that decoded cleanly, so
///   neither F187's lenient decode nor F250's raw-string round-trip could catch it — there was
///   nothing malformed to be lenient about.
/// - **Where there was a clamp, it was on the wrong side of the conversion.** `max(0, Int(seconds))`
///   traps before `max` ever runs, and F151's 30-second cap was applied after its conversion for
///   the same reason.
///
/// Named `saturating:` to read like the standard library's own `Int(exactly:)`, so it is
/// discoverable at the call site rather than a local helper someone has to already know about.
public extension Int {
    /// `value` rounded to the nearest `Int`, saturating at the bounds rather than trapping.
    ///
    /// NaN is 0: it has no ordering, so saturating either way would be a guess about which end it
    /// belongs at.
    init(saturating value: Double) {
        guard !value.isNaN else { self = 0; return }
        // Compared as `Double` on purpose. `Double(Int.max)` rounds UP to 2^63 — one past the
        // representable range — so a hand-written check that casts the other way is off by one at
        // exactly the boundary it exists to guard.
        if value >= Double(Int.max) { self = .max; return }
        if value <= Double(Int.min) { self = .min; return }
        self = Int(value.rounded())
    }
}

public extension Int64 {
    /// `value` rounded to the nearest `Int64`, saturating at the bounds rather than trapping.
    init(saturating value: Double) {
        guard !value.isNaN else { self = 0; return }
        if value >= Double(Int64.max) { self = .max; return }
        if value <= Double(Int64.min) { self = .min; return }
        self = Int64(value.rounded())
    }
}

public extension UInt32 {
    /// `value` rounded to the nearest `UInt32`, saturating at the bounds rather than trapping.
    ///
    /// Reached through the WAV header's sample-rate field, where the argument is a `Double`
    /// parameter a caller supplies.
    init(saturating value: Double) {
        guard !value.isNaN, value > 0 else { self = 0; return }
        if value >= Double(UInt32.max) { self = .max; return }
        self = UInt32(value.rounded())
    }
}

public extension Int16 {
    /// A `[-1, 1]` audio sample scaled to full-scale `Int16`, with **NaN as silence** (F354).
    ///
    /// The clamp alone is not enough, and the way it fails is counter-intuitive. `min(1, .nan)`
    /// returns `1` — `min(x, y)` is `y < x ? y : x`, and every comparison against NaN is false —
    /// so a NaN sample does not trap here. It produces **+32767**: a full-scale click, audible in
    /// `meeting.wav`, indistinguishable in the file from legitimately loud audio.
    ///
    /// Zero, not a saturated rail, because the value is not "very loud", it is "not a number", and
    /// the only honest rendering of that in a waveform is silence.
    ///
    /// **`isNaN`, not `isFinite`, and the difference was found by writing the test wrong.** The
    /// clamp handles ±infinity correctly and always did: `min(1, .infinity)` is 1 and
    /// `max(-1, -.infinity)` is -1, so an infinity saturates to the rail, which is the right answer
    /// for a value that means "louder than representable". Only NaN slips through, because every
    /// comparison against it is false and the clamp therefore returns its own bound. Rejecting
    /// infinities as well would have been a second, silent behaviour change smuggled in beside the
    /// fix — and it would have disagreed with `FloatTrackMixer`, whose limiter turns an infinite
    /// sum into a finite 1.0 before this is ever reached.
    ///
    /// **Measured before it was adopted**, since the mix runs once per frame and a 60-minute
    /// meeting is 172.8 M frames: best-of-seven over 10 M frames, 0.794 ns/frame without the check
    /// and 0.927 ns/frame with it — about 22 ms added to a 60-minute meeting.
    ///
    /// Shared rather than written twice: `FloatTrackMixer.mixedSample` and `WAVWriter.pcm16Data`
    /// had the same clamp and therefore the same defect, and F354 named only the first.
    init(clampedAudioSample sample: Float) {
        guard !sample.isNaN else { self = 0; return }
        // `Swift.max`/`Swift.min`: inside an extension on `Int16`, a bare `max` resolves to
        // `Int16.max` — the static property — and the compiler then reports "cannot call value of
        // non-function type 'Int16'", which reads like a different bug entirely.
        let clamped = Swift.max(-1, Swift.min(1, sample))
        self = Int16(clamped * Float(Int16.max))
    }
}
