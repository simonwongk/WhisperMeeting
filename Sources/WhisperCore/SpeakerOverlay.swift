import Foundation

/// What the transcript row shows for one segment. `speaker` is the only case that names a cluster,
/// and it is reached only when the conservative rule below is satisfied (F218).
public enum SpeakerOverlayLabel: Sendable, Equatable {
    /// One anonymous cluster covers this segment unambiguously.
    case speaker(clusterID: Int)
    /// More than one voice may be active here.
    case overlapping
    /// Voices are present but no single one can be named.
    case uncertain
    /// No diarization turn covers this segment at all.
    case unlabeled
}

public struct SpeakerOverlayRow: Sendable, Equatable {
    public let segmentIndex: Int
    public let label: SpeakerOverlayLabel

    public init(segmentIndex: Int, label: SpeakerOverlayLabel) {
        self.segmentIndex = segmentIndex
        self.label = label
    }
}

/// Pure reconciliation of anonymous diarization turns with timed ASR segments (F218).
///
/// This produces a *display overlay* and nothing else: `TranscriptSegment` is never mutated,
/// `transcriptText` is never touched, and the audio is never read. The thresholds are fixed policy,
/// not user-facing "confidence" controls — a benchmark may revise them only with a documented
/// before/after comparison on a held-out corpus.
///
/// Half-open `[start, end)` throughout, matching `TranscriptChapters` and `TranscriptPlayback`.
public enum SpeakerOverlay {
    /// A cluster must cover at least this fraction of the segment's duration.
    public static let minimumCoverage = 0.80
    /// …and must beat the runner-up by at least this many percentage points.
    public static let minimumMargin = 0.20
    /// Rows shorter than this are never named (F317). Derived, not chosen: on 18 annotated AMI
    /// meetings a name on a solo row under one second was right 37 % of the time, against 84 % from
    /// one to three seconds and 99.8 % beyond (`docs/DIARIZATION_SCORECARD.md`). A sub-second row
    /// is usually an interjection inside someone else's turn, and the runtime hands the whole
    /// stretch to the person holding the floor.
    public static let minimumLabelledDuration: TimeInterval = 1.0

    /// Assigns a label to each segment, returned in the caller's own segment order. Never fills a
    /// visual gap by choosing the most common speaker: an ambiguous interval reports its ambiguity.
    ///
    /// `segments` need not be sorted — the walk orders them internally (see below) — and `turns` are
    /// assumed sorted by `startSeconds`, as `SpeakerTurns.validate` guarantees.
    public static func rows(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        recordingDuration: TimeInterval?
    ) -> [SpeakerOverlayRow] {
        guard !segments.isEmpty else { return [] }
        guard !turns.isEmpty else {
            return segments.indices.map { SpeakerOverlayRow(segmentIndex: $0, label: .unlabeled) }
        }

        // Turns are validated sorted by start, so one advancing cursor is enough to keep the walk
        // linear WHILE TURNS DO NOT OVERLAP — the case a nested scan would turn into
        // O(segments x turns), regressing long transcripts the way the playback tick once did.
        //
        // The bound is not unconditional, and the comment here used to claim it was. The cursor only
        // moves past turns that END before this segment begins, so a single turn spanning a long
        // stretch pins it, and every segment inside that stretch rescans the turn list from the
        // pinned index: measured here at 63/222/876 ms for 2 000/4 000/8 000 segments against
        // 3.3/4.5/8.4 ms with no spanning turn — doubling the input quadruples it. Real diarization
        // output overlaps rarely and briefly, so the walk is linear in practice; one long spanning
        // turn (a whole-recording `.overlap`, say) would not be, and `overlayIsLinearOnLongInput`
        // builds strictly non-overlapping turns, so it cannot observe that case.
        //
        // That cursor only moves forward, so it also requires the SEGMENTS to be in ascending start
        // order. Whisper emits them that way; a merged, re-aligned or hand-edited transcript need
        // not. And an out-of-order segment does not merely degrade to `.unlabeled` — the cursor has
        // already advanced past the competing turn, so the segment is attributed to the surviving
        // cluster CONFIDENTLY, which is the one failure this module exists to prevent. So walk a
        // sorted copy of the indices and emit the rows back in the caller's own order: O(n log n)
        // once, with the linear merge walk itself untouched.
        var labels = [SpeakerOverlayLabel](repeating: .unlabeled, count: segments.count)
        let order = segments.indices.sorted {
            (Self.startKey(of: segments, at: $0), $0) < (Self.startKey(of: segments, at: $1), $1)
        }
        var cursor = 0

        for index in order {
            guard let bounds = self.bounds(of: segments, at: index, recordingDuration: recordingDuration) else {
                labels[index] = .unlabeled
                continue
            }
            // Retreat is impossible (segments advance), but a turn may span several segments, so the
            // cursor only moves past turns that end before this segment begins.
            while cursor < turns.count, turns[cursor].endSeconds <= bounds.start {
                cursor += 1
            }

            var coverageByCluster: [Int: TimeInterval] = [:]
            var overlapSeconds: TimeInterval = 0
            var uncertainSeconds: TimeInterval = 0
            var scan = cursor
            while scan < turns.count, turns[scan].startSeconds < bounds.end {
                let turn = turns[scan]
                let intersection = min(turn.endSeconds, bounds.end) - max(turn.startSeconds, bounds.start)
                if intersection > 0 {
                    switch turn.kind {
                    case .speech:
                        coverageByCluster[turn.clusterID, default: 0] += intersection
                    case .overlap:
                        overlapSeconds += intersection
                    case .uncertain:
                        uncertainSeconds += intersection
                    }
                }
                scan += 1
            }

            labels[index] = label(
                coverageByCluster: coverageByCluster,
                overlapSeconds: overlapSeconds,
                uncertainSeconds: uncertainSeconds,
                segmentDuration: bounds.end - bounds.start
            )
        }
        return segments.indices.map { SpeakerOverlayRow(segmentIndex: $0, label: labels[$0]) }
    }

    /// The key the walk is ordered by. A segment with no usable start sorts last — it is `.unlabeled`
    /// whatever order it is visited in. NaN is folded in with the absent case deliberately: a value
    /// that loses every comparison is not a strict weak ordering, and `sorted` traps on one.
    private static func startKey(of segments: [TranscriptSegment], at index: Int) -> TimeInterval {
        guard let start = segments[index].start, start.isFinite else { return .infinity }
        return start
    }

    // MARK: - Display names (F220)

    /// What a row says when more than one voice may be active in it. Shared by the transcript chip and
    /// the labeled exports so the two never drift into two vocabularies for the same finding.
    public static let overlappingName = "Overlapping voices"

    /// What a row says when voices are present but none of them can be named.
    public static let uncertainName = "Unclear which voice"

    /// A label the reader typed, folded onto one line — or nil when they cleared it.
    ///
    /// `DiarizationArtifactV1.clampedAlias` bounds the length and trims the ends but keeps interior
    /// newlines, and one of those would split a transcript line (or a one-line chip) in two.
    public static func typedAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        let folded = alias.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    /// The visible name for one row's label, or nil when the row carries no label at all.
    ///
    /// `.unlabeled` returns nil rather than an empty string on purpose: an empty chip beside a line
    /// reads as a fourth kind of speaker, which is precisely the persuasive-but-meaningless thing the
    /// abstention exists to avoid.
    public static func displayName(for label: SpeakerOverlayLabel, aliases: [Int: String]) -> String? {
        switch label {
        case let .speaker(clusterID):
            return typedAlias(aliases[clusterID]) ?? TranscriptExporter.anonymousSpeakerName(clusterID: clusterID)
        case .overlapping:
            return overlappingName
        case .uncertain:
            return uncertainName
        case .unlabeled:
            return nil
        }
    }

    /// Every row's visible label, keyed by segment index — computed ONCE, off the render path (F220).
    ///
    /// The transcript view redraws on the 4 Hz playback tick. Resolving a row's label inside the row
    /// body would put an overlay search and an alias lookup on every visible line, four times a
    /// second, which is the exact shape of the regression F160 documents for the search highlighter.
    /// So the view stores this map and the row body does one dictionary read.
    public static func labelsByIndex(
        rows: [SpeakerOverlayRow],
        aliases: [Int: String]
    ) -> [Int: String] {
        var labels: [Int: String] = [:]
        labels.reserveCapacity(rows.count)
        for row in rows {
            guard let name = displayName(for: row.label, aliases: aliases) else { continue }
            labels[row.segmentIndex] = name
        }
        return labels
    }

    /// The distinct clusters actually shown, in ascending id order — which is the order of the
    /// numbers the legend renders, since a cluster's id is its "Speaker n" number.
    public static func clusterIDs(in rows: [SpeakerOverlayRow]) -> [Int] {
        var seen: Set<Int> = []
        for row in rows {
            guard case let .speaker(clusterID) = row.label else { continue }
            seen.insert(clusterID)
        }
        // Sorted by the id, because the id IS the number the legend shows ("Speaker \(id + 1)").
        // Ordering by first labelled row instead looks like first-appearance order but is not:
        // `densify` already numbers clusters by the first TURN each one speaks, and the row carrying
        // that turn is very often abstained — 242 of 627 rows on the meeting where this was caught.
        // The legend then reads "Speaker 2, Speaker 1, Speaker 4, Speaker 3" and looks broken (F220).
        return seen.sorted()
    }

    /// The PRD's rule, in one place: an overlap anywhere in the segment vetoes a name; otherwise a
    /// cluster must clear both the coverage floor and the margin over the runner-up.
    ///
    /// **The overlap veto is implemented and tested, and is currently UNREACHABLE IN PRODUCTION.**
    /// The selected runtime does not report overlap, and this was measured rather than assumed.
    /// Given audio with 8.1 s of certain simultaneous speech
    /// (`Scripts/bench/diarization/make-ui-fixtures.sh audio` → `probe-overlap.wav`) it returns
    /// three turns and **zero intersections**, attributing the entire overlap window to one speaker
    /// as ordinary confident speech. Both speakers are found, so it is not a clustering failure:
    /// pyannote community-1 resolves simultaneity to a single winner internally.
    ///
    /// So two people talking at once do **not** arrive as two intersecting `.speech` intervals —
    /// they arrive as one interval belonging to whichever voice won — and the rule below then names
    /// that voice confidently over a stretch where both were speaking. That is the precise case the
    /// veto exists to stop, and no amount of work in `SpeakerTurns.densify` can restore information
    /// the runtime discarded before returning. (F223 proposed exactly that and was closed invalid on
    /// this evidence.) Fixing it means a runtime that can represent two speakers at once — FluidAudio
    /// ships Sortformer, whose per-speaker activity tracks can — which is F232.
    ///
    /// `overlayVetoIsUnreachableFromRuntimeOutput` pins the gap so it cannot be forgotten, and
    /// `docs/DIARIZATION_SCORECARD.md` carries the measurement.
    private static func label(
        coverageByCluster: [Int: TimeInterval],
        overlapSeconds: TimeInterval,
        uncertainSeconds: TimeInterval,
        segmentDuration: TimeInterval
    ) -> SpeakerOverlayLabel {
        guard segmentDuration > 0 else { return .unlabeled }
        if overlapSeconds > 0 { return .overlapping }
        guard !coverageByCluster.isEmpty else {
            return uncertainSeconds > 0 ? .uncertain : .unlabeled
        }
        // A hair under the floor from floating-point subtraction is still the floor.
        guard segmentDuration >= minimumLabelledDuration - 1e-9 else { return .uncertain }
        // Ties break toward the lower cluster id so the result is deterministic across runs: with
        // equal coverage the tuple comparison falls through to the ids, and the *swapped* operands
        // make the lower id sort first.
        let ranked = coverageByCluster
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let best = ranked[0]
        let bestShare = best.value / segmentDuration
        let runnerUpShare = ranked.count > 1 ? ranked[1].value / segmentDuration : 0
        guard bestShare >= minimumCoverage, bestShare - runnerUpShare >= minimumMargin else {
            return .uncertain
        }
        return .speaker(clusterID: best.key)
    }

    /// A segment's effective time range, with the same three-level fallback `TranscriptPlayback`
    /// uses: an explicit end, else the next segment's start, else the recording duration.
    private static func bounds(
        of segments: [TranscriptSegment],
        at index: Int,
        recordingDuration: TimeInterval?
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard let start = segments[index].start, start.isFinite else { return nil }
        let end = segments[index].end
            ?? segments[(index + 1)...].lazy.compactMap(\.start).first
            ?? recordingDuration
        guard let end, end.isFinite, end > start else { return nil }
        return (start, end)
    }
}
