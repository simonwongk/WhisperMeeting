import Foundation
import Testing
@testable import WhisperCore

// F218 — the overlay is cached against the timings it was computed from. The fingerprint must
// change when timings change and stay put when only the text changes, or a stale overlay survives.

private func seg(_ start: Double?, _ end: Double?, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("The fingerprint is stable across calls for the same timings (F218)")
func fingerprintIsStable() {
    let segments = [seg(0, 1, "a"), seg(1, 2, "b")]
    #expect(TranscriptTimingFingerprint.compute(segments) == TranscriptTimingFingerprint.compute(segments))
}

@Test("Editing only the text leaves the timing fingerprint unchanged (F218)")
func fingerprintIgnoresText() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "hello"), seg(1, 2, "world")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "HELLO"), seg(1, 2, "WORLD")])
    #expect(before == after)
}

@Test("Changing a timing changes the fingerprint (F218)")
func fingerprintTracksTimings() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2, "b")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2.5, "b")])
    #expect(before != after)
}

@Test("Adding or removing a segment changes the fingerprint (F218)")
func fingerprintTracksSegmentCount() {
    let before = TranscriptTimingFingerprint.compute([seg(0, 1, "a")])
    let after = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(1, 2, "b")])
    #expect(before != after)
}

@Test("Missing timings are represented distinctly rather than collapsing to zero (F218)")
func fingerprintDistinguishesMissingTimings() {
    let missing = TranscriptTimingFingerprint.compute([seg(nil, nil, "a")])
    let zeroed = TranscriptTimingFingerprint.compute([seg(0, 0, "a")])
    #expect(missing != zeroed)
}

@Test("An empty transcript has a defined fingerprint (F218)")
func fingerprintHandlesEmpty() {
    #expect(!TranscriptTimingFingerprint.compute([]).isEmpty)
}

@Test("A timing far outside any real recording folds to a sentinel instead of trapping (F218)")
func fingerprintSurvivesOutOfRangeTimings() {
    // A transcript is editable JSON on disk, so a bound can be any finite Double. Converting one
    // straight to Int64 would trap the whole app, so the out-of-range case gets its own sentinel —
    // still distinct from "no timing at all".
    let absurd = TranscriptTimingFingerprint.compute([seg(1e300, 1e300, "a")])
    let missing = TranscriptTimingFingerprint.compute([seg(nil, nil, "a")])
    #expect(!absurd.isEmpty)
    #expect(absurd != missing)
}
