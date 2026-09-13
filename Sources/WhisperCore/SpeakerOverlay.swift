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

        // Turns are validated sorted by start, so a single advancing cursor is enough, and the walk
        // never rescans from the beginning. A nested scan here would be O(segments x turns) and would
        // regress long transcripts the way the playback tick once did.
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

    /// The distinct clusters actually shown, in first-appearance order — the legend's row order, so
    /// it matches the reading order of the transcript rather than a numeric sort.
    public static func clusterIDs(in rows: [SpeakerOverlayRow]) -> [Int] {
        var seen: Set<Int> = []
        var ordered: [Int] = []
        for row in rows {
            guard case let .speaker(clusterID) = row.label, !seen.contains(clusterID) else { continue }
            seen.insert(clusterID)
            ordered.append(clusterID)
        }
        return ordered
    }

    /// The PRD's rule, in one place: an overlap anywhere in the segment vetoes a name; otherwise a
    /// cluster must clear both the coverage floor and the margin over the runner-up.
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
