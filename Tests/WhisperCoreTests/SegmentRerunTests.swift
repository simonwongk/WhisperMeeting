import Testing
@testable import WhisperCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// F77 — segment audio byte range + transcript splice.
@Test("SegmentAudioRange maps a time span to WAV byte offsets")
func segmentAudioByteRange() {
    let range = SegmentAudioRange.byteRange(startSeconds: 1.0, endSeconds: 2.0, sampleRate: 16_000)
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

@Test("An absurd decoded timestamp yields a readable byte range instead of trapping (F362)")
func segmentAudioByteRangeSurvivesAnAbsurdTimestamp() {
    let range = SegmentAudioRange.byteRange(
        startSeconds: 1e30, endSeconds: 1e30, sampleRate: 16_000, availableBytes: 64_044
    )
    #expect(range.lowerBound >= SegmentAudioRange.headerBytes)
    #expect(range.lowerBound <= range.upperBound)
    #expect(range.upperBound <= 64_044, "a range past the file cannot be read; got \(range)")
    #expect(range.count >= 0)
}

@Test("A NaN or infinite timestamp is treated as the start of the audio (F362)")
func segmentAudioByteRangeSurvivesNaNAndInfinity() {
    for bad in [Double.nan, .infinity, -.infinity] {
        let range = SegmentAudioRange.byteRange(
            startSeconds: bad, endSeconds: bad, sampleRate: 16_000, availableBytes: 64_044
        )
        #expect(range.lowerBound >= SegmentAudioRange.headerBytes, "\(bad) -> \(range)")
        #expect(range.lowerBound <= range.upperBound, "\(bad) -> \(range)")
        #expect(range.upperBound <= 64_044, "\(bad) -> \(range)")
    }
}

@Test("A negative timestamp cannot seek behind the WAV header (F362)")
func segmentAudioByteRangeSurvivesNegativeTimestamps() {
    let range = SegmentAudioRange.byteRange(
        startSeconds: -1e30, endSeconds: -5, sampleRate: 16_000, availableBytes: 64_044
    )
    #expect(range.lowerBound == SegmentAudioRange.headerBytes)
    #expect(range.lowerBound <= range.upperBound)
}

@Test("Bounding by the file does not disturb an ordinary in-range span (F362)")
func segmentAudioByteRangeLeavesOrdinarySpansAlone() {
    let range = SegmentAudioRange.byteRange(
        startSeconds: 1.0, endSeconds: 2.0, sampleRate: 16_000, availableBytes: 10_000_000
    )
    #expect(range.lowerBound == 44 + 1 * 16_000 * 2)
    #expect(range.upperBound == 44 + 2 * 16_000 * 2)
}
