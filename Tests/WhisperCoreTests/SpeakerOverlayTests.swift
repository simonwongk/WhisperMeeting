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

@Test("The overlap veto is unreachable from runtime output, so simultaneous speech is named (F232)")
func overlayVetoIsUnreachableFromRuntimeOutput() {
    // The test above is the PRD's veto — "an overlap anywhere in the segment vetoes a name" — and it
    // passes only because its fixture hand-builds a `.overlap` turn. Nothing in the shipped pipeline
    // ever does, and the reason is a layer lower than it looks.
    //
    // F223 proposed deriving `.overlap` by splitting intersecting raw turns. That was closed invalid
    // on measurement: given audio with 8.1 s of certain simultaneous speech
    // (`Scripts/bench/diarization/make-ui-fixtures.sh audio` → `probe-overlap.wav`) the runtime
    // returns three turns and ZERO intersections, attributing the whole overlap window to one
    // speaker as ordinary confident speech. Both speakers are found, so it is not a clustering
    // failure — pyannote community-1 resolves simultaneity to a single winner before
    // `OfflineDiarizerManager` returns. There is nothing for `densify` to split.
    //
    // So this file cannot be fixed from `densify`, and F232 tracks the real question: whether to
    // adopt a runtime that can represent two speakers at once (FluidAudio ships Sortformer, whose
    // per-speaker activity tracks can) or to state the limitation in the product copy.
    //
    // This test RECORDS the gap rather than approving it. When F232 lands it goes red — that is the
    // alarm, and the answer is to flip the expectations here and amend both
    // `docs/SPEAKER_DIARIZATION_PLAN.md` and the veto's doc comment, never to delete it.
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 100, rawSpeaker: 0, confidence: 0.9),
        RawDiarizationTurn(startSeconds: 40, endSeconds: 45, rawSpeaker: 1, confidence: 0.9)
    ]
    let turns = SpeakerTurns.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(!turns.contains { $0.kind == .overlap })

    // The same two intervals the veto test uses, only unmarked — and the overlay names one of the
    // two voices over five seconds in which both were talking, with no hedge at all.
    let rows = SpeakerOverlay.rows(
        segments: [seg(0, 100)],
        turns: turns,
        recordingDuration: 100
    )
    #expect(rows == [SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0))])
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

// The expectation here CHANGED, and the old one was the defect: it asserted [2, 0], i.e. order of
// first labelled row. Running a real 47-minute meeting rendered a legend reading
// "Speaker 2, Speaker 1, Speaker 4, Speaker 3" because of exactly this. Ids are already assigned by
// first-appearance of turn, so the legend must follow the id it displays (F220).
@Test("Cluster ids are listed in the order of the numbers the legend shows (F218/F220)")
func overlayListsClustersInDisplayedNumberOrder() {
    let rows = [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 2)),
        SpeakerOverlayRow(segmentIndex: 1, label: .uncertain),
        SpeakerOverlayRow(segmentIndex: 2, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 3, label: .speaker(clusterID: 2))
    ]
    #expect(SpeakerOverlay.clusterIDs(in: rows) == [0, 2])
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

// F220 — found by running the real app on a real meeting: the legend rendered
// "Speaker 2, Speaker 1, Speaker 4, Speaker 3". Cluster ids are already assigned in first-appearance
// order of TURNS by densify, but this returned first-appearance order of LABELLED ROWS. When the
// first turn's row is abstained — which happens constantly, 242 of 627 rows on that meeting — the
// two orders disagree and the legend shows its numbers out of sequence. The displayed number is the
// cluster id, so the legend must be ordered by that same id or it contradicts itself.
@Test("The legend lists speakers in their numbered order, not order of first labelled row (F220)")
func overlayLegendIsOrderedByTheNumberItDisplays() {
    let rows = [
        SpeakerOverlayRow(segmentIndex: 0, label: .uncertain),          // cluster 0 spoke, abstained
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1)),
        SpeakerOverlayRow(segmentIndex: 2, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 3, label: .speaker(clusterID: 3)),
        SpeakerOverlayRow(segmentIndex: 4, label: .speaker(clusterID: 2))
    ]
    #expect(SpeakerOverlay.clusterIDs(in: rows) == [0, 1, 2, 3])
}

@Test("A row shorter than a second is never named, however cleanly one cluster covers it (F317)")
func overlayAbstainsOnVeryShortRows() {
    // Measured on 18 annotated AMI meetings (F225): with nobody else talking, a name on a row under
    // one second was right 37 % of the time; from one to three seconds 84 %; beyond that 99.8 %.
    // A label that is wrong more often than right is worse than none.
    let rows = SpeakerOverlay.rows(
        segments: [seg(10, 10.9), seg(20, 21.0)],
        turns: [turn(0, 30, 1)],
        recordingDuration: 30
    )
    #expect(rows.map(\.label) == [.uncertain, .speaker(clusterID: 1)])
}

@Test("The one-second floor is inclusive to within a rounding error, and only gates names (F343)")
func overlayShortRowBoundaries() {
    // `seg(20, 21.0)` above is exactly 1.0, so it never exercised the `1e-9` tolerance the rule
    // carries for floating-point subtraction. 2.3 - 1.3 is 0.9999999999999998 in binary64 — a
    // genuine one-second row that a strict `>=` would abstain on.
    #expect(2.3 - 1.3 < 1.0, "the premise: this subtraction really does land under the floor")
    let aHairUnder = SpeakerOverlay.rows(
        segments: [seg(1.3, 2.3)], turns: [turn(0, 30, 1)], recordingDuration: 30
    )
    #expect(aHairUnder.map(\.label) == [.speaker(clusterID: 1)], "a hair under from arithmetic is still a second")

    let clearlyUnder = SpeakerOverlay.rows(
        segments: [seg(9.1, 10.0)], turns: [turn(0, 30, 1)], recordingDuration: 30
    )
    #expect(clearlyUnder.map(\.label) == [.uncertain])

    // The guard ORDER the UI depends on: a short row with no coverage at all stays `.unlabeled`,
    // not `.uncertain`. "Unclear which voice" claims voices were heard here; nothing was.
    let noCoverage = SpeakerOverlay.rows(
        segments: [seg(40, 40.5)], turns: [turn(0, 30, 1)], recordingDuration: 60
    )
    #expect(noCoverage.map(\.label) == [.unlabeled])

    #expect(SpeakerOverlay.minimumLabelledDuration == 1.0)
}

@Test("A final segment with no end is measured against its derived bounds, not its speech (F343)")
func overlayShortFinalSegmentUsesDerivedBounds() {
    // A last segment with only a start runs to the recording's end, so a genuinely sub-second one
    // is measured against the whole tail and sails past the one-second floor. That is deliberate,
    // not an oversight: coverage is computed over the same derived bounds, so the two agree — and
    // the coverage rule is what actually protects the row. Pinned here so a future change to either
    // half has to face the other.
    let spanning = SpeakerOverlay.rows(
        segments: [seg(0, 5), seg(29.5, nil)],
        turns: [turn(0, 60, 1)],
        recordingDuration: 60
    )
    #expect(spanning.map(\.label) == [.speaker(clusterID: 1), .speaker(clusterID: 1)],
            "a 0.5 s segment, measured as 30.5 s — and the same voice holds all of it, so naming it is right")

    // The shape that would be wrong — 0.4 s of speech inside a 30 s derived row — is refused by the
    // coverage floor long before the duration floor could have been asked.
    let brief = SpeakerOverlay.rows(
        segments: [seg(0, 5), seg(29.5, nil)],
        turns: [turn(0, 5, 1), turn(29.5, 29.9, 2)],
        recordingDuration: 60
    )
    #expect(brief.map(\.label) == [.speaker(clusterID: 1), .uncertain])
}
