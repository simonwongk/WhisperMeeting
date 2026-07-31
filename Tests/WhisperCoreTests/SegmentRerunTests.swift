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
