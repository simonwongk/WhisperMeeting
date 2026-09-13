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

@Test("The fingerprint is a pinned 16-hex-digit value, not a per-process hash (F218)")
func fingerprintIsReproducibleAcrossProcesses() {
    // This value is persisted in diarization.json and compared against a freshly computed one after
    // a relaunch (AppModel.computeSpeakerOverlay), so the algorithm is a cross-process wire format,
    // not an implementation detail. Nothing else here would notice it changing: a per-process-seeded
    // hash (Hasher/hashValue) satisfies every other test in this file while staling every cached
    // overlay in every meeting on every launch. Golden values, recomputed independently.
    #expect(TranscriptTimingFingerprint.compute([]) == "af63bd4c8601b7df")
    #expect(TranscriptTimingFingerprint.compute([seg(0, 1, "a")]) == "d0a5ff18672b47c4")
    #expect(TranscriptTimingFingerprint.compute([seg(0, 1.5, "a"), seg(1.5, 3, "b")]) == "9e16f22299e1db45")
    // Sixteen ASCII hex digits, always: the codec bounds this field on decode, and a value that
    // outgrew the format would be refused as malformed rather than merely look different.
    let fingerprint = TranscriptTimingFingerprint.compute([seg(0, 1, "a"), seg(nil, nil, "b")])
    #expect(fingerprint.count == 16)
    #expect(fingerprint.allSatisfy { $0.isHexDigit && $0.isASCII })
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

@Test("A negative bound cannot spell either reserved sentinel (F218)")
func fingerprintSentinelsAreUnreachable() {
    // -1 ms is UInt64.max in two's complement, and -2 ms is UInt64.max - 1: exactly the two
    // sentinels. A transcript is editable JSON on disk, so "no real value reaches them" has to be
    // enforced, not assumed — otherwise two different timing sets share one fingerprint and a
    // stale overlay is shown as current.
    let missing = TranscriptTimingFingerprint.compute([seg(nil, nil, "a")])
    let absurd = TranscriptTimingFingerprint.compute([seg(1e300, 1e300, "a")])
    #expect(TranscriptTimingFingerprint.compute([seg(-0.001, -0.001, "a")]) != missing)
    #expect(TranscriptTimingFingerprint.compute([seg(-0.002, -0.002, "a")]) != missing)
    #expect(TranscriptTimingFingerprint.compute([seg(.nan, .nan, "a")]) != missing)
    #expect(TranscriptTimingFingerprint.compute([seg(.infinity, .infinity, "a")]) != missing)
    // Every unusable bound is allowed to share one sentinel; none may share the "absent" one.
    #expect(TranscriptTimingFingerprint.compute([seg(-0.002, -0.002, "a")]) == absurd)
}
