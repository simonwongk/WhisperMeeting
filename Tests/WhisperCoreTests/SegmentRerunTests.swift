import Testing
@testable import WhisperCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// F77 — segment audio byte range + transcript splice.
@Test("SegmentAudioRange maps a time span to WAV byte offsets")
func segmentAudioByteRange() throws {
    let range = try SegmentAudioRange.byteRange(startSeconds: 1.0, endSeconds: 2.0, sampleRate: 16_000)
    #expect(range.lowerBound == 44 + 1 * 16_000 * 2) // 32044
    #expect(range.upperBound == 44 + 2 * 16_000 * 2) // 64044
}

@Test("TranscriptSegmentSplice replaces one segment and anchors the re-run timestamps")
func transcriptSegmentSplice() {
    let original = [seg(0, 4, "a"), seg(5, 9, "b"), seg(10, 14, "c")]
    // The re-run produced two clip-relative segments (starts 0 and 2).
    let rerun = [seg(0, 1.5, "b1"), seg(2, 3.5, "b2")]

    let result = TranscriptSegmentSplice.splice(original, replacingIndex: 1, with: rerun)

    #expect(result.count == 4)
    #expect(result.map(\.text) == ["a", "b1", "b2", "c"])
    #expect(result[1].start == 5) // 0 + original[1].start (5)
    #expect(result[2].start == 7) // 2 + 5

    let starts = result.compactMap(\.start)
    #expect(starts == starts.sorted())           // strictly ordered
    #expect(Set(starts).count == starts.count)   // no duplicates
}

// F362 — `TranscriptSegment.start`/`.end` are plain `Double?` with a synthesised `Codable` and no
// validation, so a `meetings.json` carrying `1e30` decodes cleanly and reaches this function. `Int(Double)`
// traps rather than saturating, so "Re-transcribe this segment" aborted the app. AGENTS.md's rule applies
// twice over: `isFinite` alone would not help (1e30 is finite), and the caller's existing clamp sat on the
// wrong side of the conversion.
//
// Asserting the clamped range still READS correctly, not merely that nothing trapped — a saturated
// `Int.max` would satisfy "did not crash" and then overflow the `* bytesPerSample` multiply next to it.

// F416 — clamping was the wrong fallback. With a sane start and an absurd end, clamping produced
// `start ..< fileSize`: `makeSegmentClip` then read the whole rest of the recording (~345 MB per
// hour) on the main actor, the engine transcribed that tail, and the splice put all of it at the
// original index while the later segments stayed — so the user's transcript silently gained a
// duplicate of everything after that point. AGENTS.md: when the clever mechanism's premise is
// false, the fallback must be a deferred action and never a destructive one. Refusing is deferred;
// rewriting a transcript from the wrong audio is not.

@Test("An absurd decoded timestamp is refused rather than clamped to the end of the file (F362, F416)")
func segmentAudioByteRangeRefusesAnAbsurdTimestamp() {
    #expect(throws: SegmentAudioRangeError.self) {
        try SegmentAudioRange.byteRange(
            startSeconds: 1.0, endSeconds: 1e30, sampleRate: 16_000, availableBytes: 64_044
        )
    }
}

@Test("A segment that starts past the end of the recording is refused too (F416)")
func segmentAudioByteRangeRefusesAStartPastTheRecording() {
    #expect(throws: SegmentAudioRangeError.self) {
        try SegmentAudioRange.byteRange(
            startSeconds: 600, endSeconds: 601, sampleRate: 16_000, availableBytes: 64_044
        )
    }
}

@Test("A segment ending a hair past the audio is still allowed (F416)")
func segmentAudioByteRangeToleratesRoundingAtTheEnd() throws {
    // The last segment of a real transcript routinely ends a fraction of a second past the final
    // sample. Refusing there would make the feature unusable on the one segment most likely to
    // need a re-run, so the refusal has a one-second tolerance and this is the control for it.
    let fileSize = 44 + 2 * 16_000 * 2
    let range = try SegmentAudioRange.byteRange(
        startSeconds: 1.0, endSeconds: 2.2, sampleRate: 16_000, availableBytes: fileSize
    )
    #expect(range.lowerBound == 44 + 1 * 16_000 * 2)
    #expect(range.upperBound == fileSize, "the clip stops at the audio that exists")
}

@Test("A NaN or infinite timestamp is treated as the start of the audio (F362)")
func segmentAudioByteRangeSurvivesNaNAndInfinity() throws {
    for bad in [Double.nan, .infinity, -.infinity] {
        let range = try SegmentAudioRange.byteRange(
            startSeconds: bad, endSeconds: bad, sampleRate: 16_000, availableBytes: 64_044
        )
        #expect(range.lowerBound >= SegmentAudioRange.headerBytes, "\(bad) -> \(range)")
        #expect(range.lowerBound <= range.upperBound, "\(bad) -> \(range)")
        #expect(range.upperBound <= 64_044, "\(bad) -> \(range)")
    }
}

@Test("A negative timestamp cannot seek behind the WAV header (F362)")
func segmentAudioByteRangeSurvivesNegativeTimestamps() throws {
    let range = try SegmentAudioRange.byteRange(
        startSeconds: -1e30, endSeconds: -5, sampleRate: 16_000, availableBytes: 64_044
    )
    #expect(range.lowerBound == SegmentAudioRange.headerBytes)
    #expect(range.lowerBound <= range.upperBound)
}

@Test("Bounding by the file does not disturb an ordinary in-range span (F362)")
func segmentAudioByteRangeLeavesOrdinarySpansAlone() throws {
    let range = try SegmentAudioRange.byteRange(
        startSeconds: 1.0, endSeconds: 2.0, sampleRate: 16_000, availableBytes: 10_000_000
    )
    #expect(range.lowerBound == 44 + 1 * 16_000 * 2)
    #expect(range.upperBound == 44 + 2 * 16_000 * 2)
}

@Test("The splice anchors on the clamped start, not a negative one (F416)")
func spliceAnchorsOnTheClampedStart() {
    // A negative start clips from byte 0 — `byteOffset` floors at the header — so anchoring the
    // re-run at the negative value puts the replacement text at a time the clip never covered.
    // The two halves have to agree about where the clip began.
    let original = [seg(-5, 4, "a"), seg(5, 9, "b")]
    let rerun = [seg(0, 1.5, "a1")]

    let result = TranscriptSegmentSplice.splice(original, replacingIndex: 0, with: rerun)

    #expect(result.map(\.text) == ["a1", "b"])
    #expect(result[0].start == 0, "clipped from the start of the audio, so anchored there too")
    #expect(result[0].end == 1.5)
}
