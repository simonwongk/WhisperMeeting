import Foundation

/// How much silence to insert when captured buffers skip forward in time (F151).
///
/// `FloatTrackWriter` records a presentation time for the **first** buffer only and writes every
/// later one contiguously. So when ScreenCaptureKit drops or stalls buffers mid-recording, the
/// samples after the gap pack earlier than their true time: the track ends up shorter than the
/// meeting, every timestamp after the gap is wrong, and — because the microphone and system streams
/// drop independently — the two channels desync for the rest of the recording.
///
/// The invariant is F275's, `sample offset == elapsed time`, broken by a different cause. F275 pads
/// a gap it already knows the length of, because it caused the restart. Here the gap has to be
/// *detected* from the timestamps, which is the whole of this decision and why it is pinned
/// separately.
///
/// Pure, so the arithmetic is testable without an `SCStream` — the position F278 had to create
/// before F276's durability could be checked at all.
public enum CaptureGapPolicy {
    /// Below this many frames a discrepancy is jitter, not a gap.
    ///
    /// Presentation timestamps are not exact multiples of the buffer size, so a naive
    /// expected-minus-actual pads a frame or two on *nearly every buffer*. That would desync the
    /// channels slowly — and a slow desync is far harder to notice than the bug being fixed here,
    /// so the tolerance is protecting against the fix, not against the platform.
    ///
    /// 480 frames is 10 ms at 48 kHz: an order of magnitude below the ~21 ms of a 1024-frame buffer,
    /// and well above the sub-millisecond drift of a healthy stream.
    public static let toleranceFrames = 480

    /// The most silence one gap may contribute.
    ///
    /// A wild timestamp — a clock jump, or a stream resuming after a suspend the capture never saw
    /// — must not turn a single buffer into hours of zeros written on the `sampleHandlerQueue`.
    /// 30 seconds at 48 kHz, and the reasoning is F275's cap: bounded silence beats an unbounded
    /// write. A genuine outage longer than this is F275's business, not a dropped buffer's.
    public static let maximumGapFrames = 48_000 * 30

    /// Frames of silence to write before a buffer whose audio begins `presentationOffset` seconds
    /// after the track's first buffer, given `writtenFrames` already on disk.
    ///
    /// Returns 0 for the ordinary case, which is every buffer of a healthy capture.
    public static func paddingFrames(
        presentationOffset: TimeInterval,
        writtenFrames: Int64,
        sampleRate: Double
    ) -> Int64 {
        // `presentationOffset > 0` rather than `isFinite`, which is not enough: NaN fails every
        // comparison and so returns here, and a negative offset is the early-buffer case below.
        guard sampleRate > 0, presentationOffset > 0, presentationOffset.isFinite else { return 0 }
        // **Clamped in the Double domain, before any Int64 conversion.** `Int64(Double)` TRAPS on
        // overflow in Swift rather than saturating, and this runs on the `sampleHandlerQueue` for
        // every buffer — so a wild-but-finite timestamp (1e18 is finite; 1e18 × 48000 is far past
        // `Int64.max`) crashed the app mid-recording, losing the meeting to a guard meant to
        // protect it. Observed as `Fatal error: Double value cannot be converted to Int64`, by a
        // test written during self-review of this very function.
        //
        // Clamping to "what is already written, plus the cap" makes the conversion unconditionally
        // safe and yields exactly the capped gap the cap below would have produced anyway. Same
        // class as `WAVWriter`'s `&*` (F278): past the representable range the answer is wrong
        // either way, and clamping cannot lose a recording while trapping can.
        let ceilingSeconds = (Double(writtenFrames) + Double(maximumGapFrames)) / sampleRate
        let expected = Int64(saturating: (min(ceilingSeconds, presentationOffset) * sampleRate).rounded())
        let gap = expected - writtenFrames
        // A buffer arriving EARLY — overlapping timestamps from a clock correction or a
        // re-delivery — cannot be fixed by truncating, because those samples are already written.
        // Adding nothing lets the track run slightly long, which is the honest failure; the
        // alternative would corrupt audio to tidy a number.
        guard gap > Int64(toleranceFrames) else { return 0 }
        // The WHOLE gap, not the amount above the tolerance: once it is a real gap, all of it is
        // audio that never arrived, and padding the excess only would leave the track permanently
        // short by the tolerance.
        return min(gap, Int64(maximumGapFrames))
    }

    /// How far a track may sit off its clock before it is steered back, one frame per buffer
    /// (F556). 240 frames is 5 ms at 48 kHz, half of `toleranceFrames`.
    ///
    /// `paddingFrames` cannot tell a dropped buffer from a device whose sample clock runs slightly
    /// off host time: both show up as presentation offsets ahead of the frames written. A dropped
    /// buffer is one step; drift is the same difference built up a fraction of a frame per buffer. A
    /// microphone 50 ppm slow falls 2.4 frames behind a second, so the old policy let it reach 480
    /// frames and then wrote a 10 ms block of zeros into it, every 200 s, mid-speech. One 50 ppm fast
    /// ran ahead with nothing correcting it, because an early buffer is never padded.
    ///
    /// So inside the band `paddingFrames` ignores, drift is corrected by a single frame: written
    /// twice when the track is behind, left out when it is ahead. One frame of a 1,024-frame buffer
    /// is inaudible, where 480 zeros are a tick. One frame per buffer corrects up to about 1,000 ppm
    /// at ScreenCaptureKit's buffer size, twenty times the drift the ticket worked from; a clock
    /// worse than that falls back to the old behaviour on each side, which is no worse than before.
    ///
    /// Not resampling. A rate estimate fed into the converter is what the ticket proposed if drift
    /// showed up, and it would hold a track closer than 5 ms; it also needs a measured drift to tune
    /// against, which no recording has given yet (F556's measurement is the user's). This keeps
    /// `sample offset == elapsed time` within 5 ms with nothing to tune, and the counts it logs at
    /// Stop are that measurement.
    ///
    /// Why 5 ms. Far enough above timestamp jitter that a healthy stream is never touched (the
    /// tolerance above calls that jitter sub-millisecond, which nobody has measured either), and
    /// far enough below 10 ms that a drifting track never reaches the gap tolerance.
    public static let driftToleranceFrames = 240

    /// What to do with one captured buffer of `bufferFrames` frames that begins `presentationOffset`
    /// seconds after the track's first buffer, given `writtenFrames` already on disk (F151, F556).
    ///
    /// - A gap past `toleranceFrames`: `paddingFrames`, unchanged — F151's whole gap, capped.
    /// - Behind by more than `driftToleranceFrames`, up to the gap tolerance: repeat the buffer's
    ///   first frame.
    /// - Ahead by more than `driftToleranceFrames`, up to the gap tolerance: leave the first frame
    ///   out, never emptying a buffer.
    /// - Ahead by more than the gap tolerance: nothing, as F151 decided for an early buffer — a step
    ///   that size is a clock correction or a re-delivery, not drift, and the old answer stands
    ///   beside the new one rather than being replaced by it.
    /// - Anything else, including a non-finite or negative offset: nothing.
    public static func alignment(
        presentationOffset: TimeInterval,
        writtenFrames: Int64,
        bufferFrames: Int,
        sampleRate: Double
    ) -> CaptureAlignment {
        let padding = paddingFrames(
            presentationOffset: presentationOffset, writtenFrames: writtenFrames, sampleRate: sampleRate
        )
        if padding > 0 { return .padSilence(padding) }
        guard sampleRate > 0, presentationOffset.isFinite, presentationOffset >= 0, bufferFrames > 0 else {
            return .none
        }
        // `saturating:` for F151's reason; a finite offset that would saturate here has already been
        // answered by `paddingFrames` above. Both terms are non-negative, so the difference cannot
        // overflow.
        let expected = Int64(saturating: (presentationOffset * sampleRate).rounded())
        let discrepancy = expected - writtenFrames
        let drift = Int64(driftToleranceFrames)
        if discrepancy > drift { return .repeatFirstFrame }
        if discrepancy < -drift, discrepancy >= -Int64(toleranceFrames), bufferFrames > 1 { return .skipFirstFrame }
        return .none
    }
}

/// What `CaptureGapPolicy.alignment` decided for one captured buffer (F556).
public enum CaptureAlignment: Equatable, Sendable {
    /// Write the buffer as it is: the healthy case, every buffer of a capture on time.
    case none
    /// Write this many frames of silence first: the stream skipped a span (F151).
    case padSilence(Int64)
    /// Write the buffer's first frame twice: the track had fallen behind its clock (F556).
    case repeatFirstFrame
    /// Leave the buffer's first frame out: the track had run ahead of its clock (F556).
    case skipFirstFrame
}
