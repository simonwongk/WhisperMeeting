import Foundation
import Testing
@testable import WhisperCore

// F151 — `FloatTrackWriter` records a presentation time for the FIRST buffer only and writes every
// later buffer contiguously. So if ScreenCaptureKit drops or stalls buffers mid-recording, the
// samples after the gap pack earlier than their true time: the track gets shorter than the meeting,
// and the microphone and system channels — which drop independently — desync for the rest of it.
//
// This is the same invariant F275 protects, `sample offset == elapsed time`, broken by a different
// cause. F275 pads a gap it knows about because it caused the restart; this one has to be *detected*
// from the timestamps, which is why the decision is worth pinning separately.
//
// Pure, so the arithmetic is testable without an `SCStream` — the reason F278 had to exist before
// F276 could be checked at all.

private let rate = 48_000.0

@Test("A contiguous buffer needs no padding (F151)")
func contiguousBufferNeedsNoPadding() {
    // The common case, on every buffer of a healthy capture. It must cost nothing and pad nothing.
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: 1.0, writtenFrames: 48_000, sampleRate: rate
    ) == 0)
}

@Test("A dropped span is padded by exactly the frames it was missing (F151)")
func droppedSpanIsPadded() {
    // 48,000 frames written, but this buffer says it starts 2 s in — so 1 s of audio never arrived.
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: 2.0, writtenFrames: 48_000, sampleRate: rate
    ) == 48_000)
}

@Test("Sub-tolerance jitter is not a gap (F151)")
func jitterIsNotAGap() {
    // Presentation timestamps are not exact multiples of the buffer size, so a naive
    // expected-minus-actual pads a frame or two on nearly every buffer — which would itself desync
    // the channels, slowly, and be far harder to notice than the bug being fixed.
    let tolerance = CaptureGapPolicy.toleranceFrames
    for drift in [1, tolerance / 2, tolerance] {
        let offset = Double(48_000 + drift) / rate
        #expect(CaptureGapPolicy.paddingFrames(
            presentationOffset: offset, writtenFrames: 48_000, sampleRate: rate
        ) == 0, "padded a \(drift)-frame jitter")
    }
}

@Test("A gap just past the tolerance is padded in full, not by the excess (F151)")
func paddingIsTheWholeGap() {
    // Once it is a real gap, the whole gap is missing audio. Padding only the amount above the
    // tolerance would leave the track permanently short by the tolerance.
    let frames = 48_000 + CaptureGapPolicy.toleranceFrames + 1
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: Double(frames) / rate, writtenFrames: 48_000, sampleRate: rate
    ) == Int64(CaptureGapPolicy.toleranceFrames + 1))
}

@Test("A buffer that arrives EARLY is never padded negatively (F151)")
func earlyBufferIsNotPadded() {
    // Overlapping timestamps happen — a clock correction, or a re-delivered buffer. Truncating is
    // not an option here (the samples are already written), so the honest answer is to add nothing
    // and let the track run slightly long rather than corrupt it.
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: 0.5, writtenFrames: 48_000, sampleRate: rate
    ) == 0)
}

@Test("The first buffer establishes the origin and is never a gap (F151)")
func firstBufferIsTheOrigin() {
    // `presentationOffset` is measured from the track's own first buffer, so the first one is 0 at
    // 0 frames written. If this padded, every recording would start with silence.
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: 0, writtenFrames: 0, sampleRate: rate
    ) == 0)
}

@Test("An absurd gap is capped rather than writing gigabytes of silence (F151)")
func absurdGapIsCapped() {
    // A wild timestamp — a clock jump, a stream resuming after a suspend the capture did not see —
    // must not turn one buffer into hours of zeros on the capture queue. Same reasoning as F275's
    // padding cap, and the same direction: bounded silence beats an unbounded write.
    let capped = CaptureGapPolicy.paddingFrames(
        presentationOffset: 60 * 60, writtenFrames: 48_000, sampleRate: rate
    )
    #expect(capped == Int64(CaptureGapPolicy.maximumGapFrames))
    #expect(CaptureGapPolicy.maximumGapFrames == 48_000 * 30)
}

@Test("A zero or negative sample rate pads nothing rather than dividing by it (F151)")
func invalidSampleRateIsSafe() {
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: 5, writtenFrames: 0, sampleRate: 0
    ) == 0)
}

@Test("An absurd but finite timestamp does not trap the capture queue (F151)")
func absurdFiniteTimestampDoesNotTrap() {
    // `Int64(Double)` TRAPS on overflow in Swift rather than saturating, and this runs on the
    // `sampleHandlerQueue` for every buffer — so a wild-but-finite presentation timestamp would
    // crash the app mid-recording, losing the meeting to a guard meant to protect it. `isFinite`
    // does not cover this: 1e18 is perfectly finite and 1e18 × 48000 is far past `Int64.max`.
    //
    // Same class as `WAVWriter`'s `&*` (F278): past the representable range the answer is wrong
    // either way, and wrapping or clamping cannot lose a recording while trapping can.
    let absurd = CaptureGapPolicy.paddingFrames(
        presentationOffset: 1e18, writtenFrames: 0, sampleRate: 48_000
    )
    #expect(absurd == Int64(CaptureGapPolicy.maximumGapFrames))

    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: -1e18, writtenFrames: 0, sampleRate: 48_000
    ) == 0)
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: .infinity, writtenFrames: 0, sampleRate: 48_000
    ) == 0)
    #expect(CaptureGapPolicy.paddingFrames(
        presentationOffset: .nan, writtenFrames: 0, sampleRate: 48_000
    ) == 0)
}
