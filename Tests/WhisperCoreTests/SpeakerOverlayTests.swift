import Foundation
import Testing
@testable import WhisperCore

// F218 — the reconciler is where a persuasive-but-wrong label gets stopped. Each test pins one
// clause of the PRD rule: 80% coverage, a 20-point margin, and an overlap veto. Without the
// implementation every case below returns nothing at all.

private func seg(_ start: Double?, _ end: Double?, _ text: String = "x") -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private func turn(_ start: Double, _ end: Double, _ cluster: Int,
                  _ kind: SpeakerTurnKind = .speech) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: kind)
}

@Test("A segment fully covered by one cluster gets that label (F218)")
func overlayLabelsAnUnambiguousSegment() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0))])
}

@Test("A segment split evenly between two clusters gets no label (F218)")
func overlaySplitSegmentIsUnlabeled() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 5, 0), turn(5, 10, 1)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("Coverage just below the 80% floor abstains; just above it labels (F218)")
func overlayHonoursTheCoverageFloor() {
    // 79% of the segment, the rest silence — below the floor.
    let below = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 79, 0)],
        recordingDuration: 100
    )
    #expect(below == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])

    let above = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 81, 0)],
        recordingDuration: 100
    )
    #expect(above == [SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0))])
}

@Test("A runner-up within 20 points blocks the label even when coverage is high (F218)")
func overlayHonoursTheMargin() {
    // Cluster 0 covers 55%, cluster 1 covers 45%: total coverage is 100% but the margin is 10pt.
    let split = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 55, 0), turn(55, 100, 1)],
        recordingDuration: 100
    )
    #expect(split == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])

    // The case above is already stopped by the coverage floor, so it does not prove the margin rule
    // exists. Two speech turns that overlap in time — which the runtime does emit — are the only way
    // a cluster clears 80% while a runner-up is still within 20 points: 85% vs 70%.
    let contested = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 85, 0), turn(15, 85, 1)],
        recordingDuration: 100
    )
    #expect(contested == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("An overlap turn intersecting the segment vetoes any label (F218)")
func overlayVetoesOnOverlap() {
    // Cluster 0 would otherwise clear both thresholds.
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: [turn(0, 100, 0), turn(40, 45, 1, .overlap)],
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .overlapping)])
}

@Test("An uncertain turn covering the segment yields uncertain, never a cluster name (F218)")
func overlayPropagatesUncertainty() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 10)],
        turns: [turn(0, 10, 0, .uncertain)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .uncertain)])
}

@Test("A segment with no covering turn is unlabeled, not assigned to the nearest speaker (F218)")
func overlayLeavesUncoveredSegmentsUnlabeled() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(50, 60)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled)])
}

@Test("A segment without timings is unlabeled rather than guessed (F218)")
func overlaySkipsUntimedSegments() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(nil, nil)],
        turns: [turn(0, 10, 0)],
        recordingDuration: 10
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled)])
}

@Test("An open-ended segment falls back to the next start, then the recording duration (F218)")
func overlayResolvesOpenEndedSegments() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, nil), seg(10, nil)],
        turns: [turn(0, 10, 0), turn(10, 20, 1)],
        recordingDuration: 20
    )
    #expect(rows == [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1))
    ])
}

@Test("No turns at all leaves every segment unlabeled (F218)")
func overlayWithNoTurnsLabelsNothing() {
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 1), seg(1, 2)],
        turns: [],
        recordingDuration: 2
    )
    // The shape, not `allSatisfy`, which is trivially true on the empty array: this is the early
    // return taken whenever analysis ran and found no speech — the likeliest path in production —
    // and every other test here passes non-empty turns, so nothing else holds it to "one row per
    // segment, in order".
    #expect(rows == [
        SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled),
        SpeakerOverlayRow(segmentIndex: 1, label: .unlabeled)
    ])
}

@Test("Cluster ids are listed in first-appearance order for a stable legend (F218)")
func overlayListsClustersInFirstAppearanceOrder() {
    let rows = [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 2)),
        SpeakerOverlayRow(segmentIndex: 1, label: .uncertain),
        SpeakerOverlayRow(segmentIndex: 2, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 3, label: .speaker(clusterID: 2))
    ]
    #expect(SpeakerOverlay.clusterIDs(in: rows) == [2, 0])
}

@Test("Reconciling a long transcript against many turns stays linear (F218)")
func overlayIsLinearOnLongInput() {
    // 5 000 segments x 5 000 turns would be 25M interval tests if this were quadratic; the merge
    // walk keeps it linear, and this test exists because the playback tick regressed exactly that
    // way before (see TranscriptPlayback's O(n^2) note).
    let segments = (0..<5_000).map { index in seg(Double(index), Double(index) + 1) }
    let turns = (0..<5_000).map { index in turn(Double(index), Double(index) + 1, index % 3) }
    let rows = SpeakerOverlay.rows(segments: segments, turns: turns, recordingDuration: 5_000)
    #expect(rows.count == 5_000)
    #expect(rows[0].label == .speaker(clusterID: 0))
    #expect(rows[4_999].label == .speaker(clusterID: 4_999 % 3))
}

@Test("An out-of-order segment is never attributed to the wrong cluster (F218)")
func overlayHandlesSegmentsOutOfOrder() {
    // The merge walk has one forward-only cursor. Handling the later segment first advances it past
    // turn(0, 9, c0), so the earlier segment would see only cluster 7 and label it confidently — the
    // correct answer is .uncertain (c7 100%, c0 90%, a 10pt margin). Whisper emits ordered segments,
    // but a merged, re-aligned or hand-edited transcript need not, and a confidently wrong name is
    // the one failure this module exists to prevent.
    let rows = SpeakerOverlay.rows(
        segments: [seg(50, 60), seg(0, 10)],
        turns: [turn(0, 9, 0), turn(0, 60, 7)],
        recordingDuration: 60
    )
    #expect(rows.count == 2)
    // Rows come back in the CALLER's order, whatever order the walk visited them in.
    #expect(rows.map(\.segmentIndex) == [0, 1])
    #expect(rows[0] == SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 7)))
    #expect(rows[1] == SpeakerOverlayRow(segmentIndex: 1, label: .uncertain))
}

@Test("A segment with no usable start does not disturb the order of the rest (F218)")
func overlayToleratesUnsortableSegments() {
    // nil and NaN starts have no place in a sort, and a comparison NaN loses against everything is
    // not a strict weak ordering — `sorted` traps on one in a debug build. They are labelled
    // .unlabeled either way; what matters is that their neighbours are still labelled correctly.
    let rows = SpeakerOverlay.rows(
        segments: [seg(nil, nil), seg(10, 20), seg(.nan, .nan), seg(0, 10)],
        turns: [turn(0, 10, 0), turn(10, 20, 1)],
        recordingDuration: 20
    )
    #expect(rows == [
        SpeakerOverlayRow(segmentIndex: 0, label: .unlabeled),
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1)),
        SpeakerOverlayRow(segmentIndex: 2, label: .unlabeled),
        SpeakerOverlayRow(segmentIndex: 3, label: .speaker(clusterID: 0))
    ])
}
