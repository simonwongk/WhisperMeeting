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
        let expected = Int64((min(presentationOffset, ceilingSeconds) * sampleRate).rounded())
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
}
