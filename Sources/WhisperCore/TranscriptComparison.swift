import Foundation

/// One aligned span when comparing two engines' transcripts of the same audio (F73).
public struct TranscriptComparisonSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case agree          // both engines produced the same (normalized) text
        case diverge        // overlapping in time but the text differs
        case nonOverlapping // the primary segment has no counterpart in the other transcript
    }

    public let kind: Kind
    public let start: Double?
    public let primaryText: String
    public let secondaryText: String?

    public init(kind: Kind, start: Double?, primaryText: String, secondaryText: String?) {
        self.kind = kind
        self.start = start
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
}

/// Pure alignment of two `[TranscriptSegment]` by time overlap (falling back to normalized-text
/// match when a side has no timestamps), surfacing where the two engines agree vs diverge (F73).
public enum TranscriptComparison {
    /// One row per line of `primary`, each matched against `secondary` by the rules `counterpart`
    /// states (F472, F572), found through a `CounterpartIndex` rather than by scanning (F542).
    public static func compare(
        _ primary: [TranscriptSegment],
        _ secondary: [TranscriptSegment]
    ) -> [TranscriptComparisonSpan] {
        let texts = primary.map { normalize($0.text) }
        return spans(primary, texts, counterparts(primary, texts, secondary), in: secondary)
    }

    /// `compare` by the simple scan: every line against every segment (F542). This is the
    /// definition — `compare` must produce exactly this, and a test holds it to that on random
    /// transcripts — kept because the plain loop is the one a reader can check the rules against.
    static func referenceCompare(
        _ primary: [TranscriptSegment],
        _ secondary: [TranscriptSegment]
    ) -> [TranscriptComparisonSpan] {
        let texts = primary.map { normalize($0.text) }
        return spans(primary, texts, referenceCounterparts(primary, texts, secondary), in: secondary)
    }

    /// Each line's counterpart, found through the index (F542).
    static func counterparts(
        _ primary: [TranscriptSegment], _ texts: [String], _ secondary: [TranscriptSegment]
    ) -> [Counterpart?] {
        let index = CounterpartIndex(secondary)
        return zip(primary, texts).map { index.counterpart(of: $0, normalized: $1) }
    }

    /// Each line's counterpart, by `counterpart`'s scan.
    static func referenceCounterparts(
        _ primary: [TranscriptSegment], _ texts: [String], _ secondary: [TranscriptSegment]
    ) -> [Counterpart?] {
        // Once per segment rather than once per pair: the scan reads each of these for every line.
        let secondaryTexts = secondary.map { normalize($0.text) }
        return zip(primary, texts).map { counterpart(of: $0, normalized: $1, in: secondary, secondaryTexts) }
    }

    private static func spans(
        _ primary: [TranscriptSegment], _ texts: [String], _ found: [Counterpart?], in secondary: [TranscriptSegment]
    ) -> [TranscriptComparisonSpan] {
        primary.indices.map { span(for: primary[$0], normalized: texts[$0], found[$0], in: secondary) }
    }

    /// What one line was matched with: the index of a segment that says the same thing, or else the
    /// indices of every segment that covers it (F572). Both are indices into the other transcript.
    enum Counterpart: Equatable {
        case agreeing(Int)
        case covering([Int])
    }

    /// A counterpart must share at least this fraction of the SHORTER of the two spans (F572).
    ///
    /// Engines' boundaries routinely disagree by a fraction of a second, so the other engine's
    /// neighbouring sentence overlaps most lines by a sliver. Counting that sliver joined the
    /// neighbour's words into the offered text, and where the other engine had dropped the line
    /// entirely it was the WHOLE offered text — Replace then wrote a neighbour's sentence over a
    /// line nobody else transcribed. Measured against the shorter span so that a short segment the
    /// line fully contains, and a long one that fully contains a short line, both count.
    ///
    /// What this does NOT stop, because a fraction of the shorter span cannot (F658): a SHORT
    /// neighbour a few tenths of a second early still shares a quarter of its own length, so it is
    /// joined in and Replace writes it twice; a short straddler ("Yeah.") still stands in for a line
    /// the other engine dropped; and a tail the line shares with a LONG segment, under a quarter of
    /// the line, is still left out. No threshold fixes all three — raising it trades the first for
    /// more of the third.
    static let minimumOverlapFraction = 0.25

    /// The other engine's reading of `segment` (F472, F572).
    ///
    /// Two segments align when their time spans overlap; if a side lacks timestamps, a
    /// normalized-text match stands in, so a timestamp-less (e.g. unaligned Qwen) passage can still
    /// compare. Of everything that aligns:
    ///
    /// - the first one that says the same thing wins — both engines did say it here, so the row
    ///   agrees and Replace is not offered (F472);
    /// - otherwise EVERY timed segment that shares at least `minimumOverlapFraction` of the shorter
    ///   span, joined in time order (F572).
    ///
    /// F472 took the one segment with the longest overlap. When the engines split sentences
    /// differently that is still one piece of the other engine's reading: this line's "A. B." over
    /// the other engine's "A." and "B." offered "B.", and Replace wrote "B." over "A. B." — "A.",
    /// which both engines heard, deleted. Before F472 it took the first overlap, which dropped "B."
    /// instead. Preferring agreement over overlap is the same caution as ever — when in doubt, offer
    /// nothing to replace rather than a neighbour's words.
    ///
    /// This is the simple scan — every segment, for every line, O(n·m) over the two transcripts —
    /// and the definition `CounterpartIndex.counterpart` reproduces in one pass (F542). `covering`
    /// lists indices in ascending order, which the index matches, so the two compare exactly.
    static func counterpart(
        of segment: TranscriptSegment,
        normalized text: String,
        in secondary: [TranscriptSegment],
        _ secondaryTexts: [String]
    ) -> Counterpart? {
        var covering: [Int] = []
        for (index, candidate) in secondary.enumerated() {
            if let overlap = sharedSeconds(segment, candidate) {
                guard overlap > 0 else { continue }
                if secondaryTexts[index] == text { return .agreeing(index) }
                if covers(segment, candidate, sharing: overlap) { covering.append(index) }
            } else if secondaryTexts[index] == text {
                return .agreeing(index)
            }
        }
        return covering.isEmpty ? nil : .covering(covering)
    }

    /// The row for one line, given what it was matched with.
    static func span(
        for segment: TranscriptSegment,
        normalized text: String,
        _ counterpart: Counterpart?,
        in secondary: [TranscriptSegment]
    ) -> TranscriptComparisonSpan {
        switch counterpart {
        case nil:
            return TranscriptComparisonSpan(
                kind: .nonOverlapping, start: segment.start, primaryText: segment.text, secondaryText: nil
            )
        case let .agreeing(index):
            return TranscriptComparisonSpan(
                kind: .agree, start: segment.start, primaryText: segment.text, secondaryText: secondary[index].text
            )
        case let .covering(indices):
            let joined = joinedInTimeOrder(indices.map { ($0, secondary[$0]) })
            // Several pieces can say, together, exactly what this line says — the same words split
            // at a different place. That is agreement, and nothing is offered to replace.
            return TranscriptComparisonSpan(
                kind: normalize(joined) == text ? .agree : .diverge, start: segment.start,
                primaryText: segment.text, secondaryText: joined
            )
        }
    }

    /// Whether `candidate`, which shares `overlap` seconds with `segment`, is part of its reading
    /// rather than a neighbour that brushes it (F572). A zero-length segment inside the other's span
    /// has a zero shorter span, so it counts, as it always has (`sharedSeconds`).
    static func covers(_ segment: TranscriptSegment, _ candidate: TranscriptSegment, sharing overlap: Double) -> Bool {
        guard let aStart = segment.start, let aEnd = segment.end,
              let bStart = candidate.start, let bEnd = candidate.end else { return false }
        return overlap >= minimumOverlapFraction * min(aEnd - aStart, bEnd - bStart)
    }

    /// The texts of `pieces` in the order they were said: by start time, then by their place in the
    /// other transcript. Joined with a space, except between two characters of a script that has
    /// none — the rule `qwen_transcribe.joined_text` applies at a chunk boundary (F562) — so two
    /// Mandarin sentences are not written back into the line with a space between them.
    static func joinedInTimeOrder(_ pieces: [(index: Int, segment: TranscriptSegment)]) -> String {
        let ordered = pieces.sorted { lhs, rhs in
            let (l, r) = (lhs.segment.start ?? 0, rhs.segment.start ?? 0)
            return l == r ? lhs.index < rhs.index : l < r
        }
        var result = ""
        for piece in ordered {
            let text = piece.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = text.unicodeScalars.first,
               !(isUnspaced(last) && isUnspaced(first)) {
                result.append(" ")
            }
            result.append(text)
        }
        return result
    }

    /// A CJK ideograph, or CJK / full-width punctuation such as '。' and '，' — `_is_cjk_or_fullwidth`
    /// in `Scripts/qwen_transcribe.py`, plus the ideograph blocks `normalize` already treats so.
    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        if ActionItemEvidence.isCJKIdeograph(scalar) { return true }
        switch scalar.value {
        case 0x3000...0x303F, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    /// Seconds two timed segments share — zero when they do not overlap — or nil when either lacks
    /// a timestamp, which is when a text match has to stand in.
    ///
    /// A zero-length segment inside the other's span shares no time but did occur within it, so it
    /// counts as the smallest possible overlap rather than none: the `aStart < bEnd && bStart < aEnd`
    /// test this replaced counted it too.
    private static func sharedSeconds(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Double? {
        guard let aStart = a.start, let aEnd = a.end, let bStart = b.start, let bEnd = b.end else { return nil }
        guard aStart < bEnd, bStart < aEnd else { return 0 }
        return max(.leastNonzeroMagnitude, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Lowercased letters and digits, with a space kept only where it separates two words of a
    /// spaced script (F570). Chinese has no word spaces, so a space kept beside an ideograph — where
    /// one engine wrote '，' and the other wrote nothing — made identical words compare unequal.
    static func normalize(_ text: String) -> String {
        let pieces = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var result = ""
        for piece in pieces {
            if let last = result.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !ActionItemEvidence.isCJKIdeograph(last), !ActionItemEvidence.isCJKIdeograph(first) {
                result.append(" ")
            }
            result.append(piece)
        }
        return result
    }
}

extension TranscriptComparison {
    /// The other transcript arranged so each line's counterpart is found without scanning all of it
    /// (F542). Built once per comparison; `counterpart(of:normalized:)` returns exactly what the
    /// simple scan `TranscriptComparison.counterpart` does.
    ///
    /// The scan cost every line a pass over every segment. On a six-hour meeting — about 6,000
    /// lines a side — that was 36 million pair checks on the main actor when the other engine
    /// finished. What the scan decides for one timed line depends on only two things, and both are
    /// looked up here instead:
    ///
    /// - **the segments whose span overlaps it** — a segment tree over the timed segments in start
    ///   order, holding the latest end under each node, reports exactly those, visiting only the
    ///   subtrees that can hold one;
    /// - **the first untimed segment saying the same text** — the scan's text-match fallback, which
    ///   for a timed line only an untimed segment can take, from a dictionary.
    ///
    /// The first agreeing segment is then the lower of the first overlapping one that says the same
    /// text and that untimed one. A line with no timestamps can match any segment by its text only,
    /// which is a second dictionary (`firstSaying`). The per-line work is a binary search plus the
    /// overlapping segments themselves, instead of the whole other transcript.
    struct CounterpartIndex {
        private let secondary: [TranscriptSegment]
        private let texts: [String]
        /// The first segment saying each normalized text — all a line without timestamps can match,
        /// since every pair it is in lacks a timestamp.
        private let firstSaying: [String: Int]
        /// The first segment without a timestamp saying each normalized text — the only text match
        /// the scan lets a TIMED line make.
        private let firstUntimedSaying: [String: Int]
        /// Indices of the timed segments, by start and then by index.
        private let order: [Int]
        /// `secondary[order[k]].start`, ascending.
        private let starts: [Double]
        /// A segment tree over `order`: node 1 is the root, node `n`'s children are `2n` and `2n+1`,
        /// and leaf `k` is node `leafBase + k`. Each node holds the latest end beneath it (−∞ under
        /// an empty leaf), which is what lets a whole subtree be skipped.
        private let latestEnd: [Double]
        private let leafBase: Int

        init(_ secondary: [TranscriptSegment]) {
            self.secondary = secondary
            let texts = secondary.map { TranscriptComparison.normalize($0.text) }
            self.texts = texts
            var firstSaying: [String: Int] = [:]
            var firstUntimedSaying: [String: Int] = [:]
            var timed: [Int] = []
            for (index, segment) in secondary.enumerated() {
                if firstSaying[texts[index]] == nil { firstSaying[texts[index]] = index }
                guard let start = segment.start, let end = segment.end else {
                    if firstUntimedSaying[texts[index]] == nil { firstUntimedSaying[texts[index]] = index }
                    continue
                }
                // A NaN timestamp is still a timestamp — the pair is not untimed, so no text match —
                // and it overlaps nothing, since every comparison with it is false. The scan skips
                // such a segment for every timed line, and so does leaving it out of the tree.
                guard !start.isNaN, !end.isNaN else { continue }
                timed.append(index)
            }
            timed.sort { lhs, rhs in
                let (l, r) = (secondary[lhs].start ?? 0, secondary[rhs].start ?? 0)
                return l == r ? lhs < rhs : l < r
            }
            var leafBase = 1
            while leafBase < timed.count { leafBase *= 2 }
            var latestEnd = [Double](repeating: -.infinity, count: 2 * leafBase)
            for (position, index) in timed.enumerated() {
                latestEnd[leafBase + position] = secondary[index].end ?? -.infinity
            }
            for node in stride(from: leafBase - 1, through: 1, by: -1) {
                latestEnd[node] = Swift.max(latestEnd[2 * node], latestEnd[2 * node + 1])
            }
            self.firstSaying = firstSaying
            self.firstUntimedSaying = firstUntimedSaying
            self.order = timed
            self.starts = timed.map { secondary[$0].start ?? 0 }
            self.latestEnd = latestEnd
            self.leafBase = leafBase
        }

        func counterpart(of segment: TranscriptSegment, normalized text: String) -> Counterpart? {
            guard let start = segment.start, let end = segment.end else {
                return firstSaying[text].map(Counterpart.agreeing)
            }
            let overlapping = overlappingIndices(start: start, end: end)
            // Ascending, so the first that says the same text is the earliest overlapping one.
            let agreeingOverlap = overlapping.first { texts[$0] == text }
            switch (agreeingOverlap, firstUntimedSaying[text]) {
            case let (overlap?, untimed?): return .agreeing(Swift.min(overlap, untimed))
            case let (overlap?, nil): return .agreeing(overlap)
            case let (nil, untimed?): return .agreeing(untimed)
            case (nil, nil): break
            }
            let covering = overlapping.filter { index in
                let candidate = secondary[index]
                guard let overlap = TranscriptComparison.sharedSeconds(segment, candidate) else { return false }
                return TranscriptComparison.covers(segment, candidate, sharing: overlap)
            }
            return covering.isEmpty ? nil : .covering(covering)
        }

        /// Indices, ascending, of the timed segments sharing time with `start..<end` by the scan's
        /// own test (`sharedSeconds`): the segment starts before the line ends, and ends after it
        /// starts. A NaN bound compares false both ways, so it finds nothing, as the scan does.
        private func overlappingIndices(start: Double, end: Double) -> [Int] {
            // The timed segments starting before the line ends are a prefix of `order`.
            var lower = 0
            var upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] < end { lower = middle + 1 } else { upper = middle }
            }
            var found: [Int] = []
            collect(node: 1, covering: 0..<leafBase, before: lower, endingAfter: start, into: &found)
            found.sort()
            return found
        }

        /// Reports every leaf under `node` whose position is below `limit` and whose end is after
        /// `start`, skipping a subtree whose latest end is not — written `>` on purpose, so a NaN
        /// start skips everything rather than visiting it.
        private func collect(
            node: Int, covering positions: Range<Int>, before limit: Int, endingAfter start: Double,
            into found: inout [Int]
        ) {
            guard positions.lowerBound < limit, latestEnd[node] > start else { return }
            if positions.count == 1 {
                found.append(order[positions.lowerBound])
                return
            }
            let middle = positions.lowerBound + positions.count / 2
            collect(node: 2 * node, covering: positions.lowerBound..<middle, before: limit, endingAfter: start, into: &found)
            collect(node: 2 * node + 1, covering: middle..<positions.upperBound, before: limit, endingAfter: start, into: &found)
        }
    }
}
