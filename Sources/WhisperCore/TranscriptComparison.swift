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
    public static func compare(
        _ primary: [TranscriptSegment],
        _ secondary: [TranscriptSegment]
    ) -> [TranscriptComparisonSpan] {
        // Once per segment rather than once per pair: the counterpart search reads each of these
        // for every line it compares.
        let secondaryTexts = secondary.map { normalize($0.text) }
        return primary.map { segment in
            let text = normalize(segment.text)
            let found = counterpart(of: segment, normalized: text, in: secondary, secondaryTexts)
            return span(for: segment, normalized: text, found, in: secondary)
        }
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
    /// This is the simple scan: every line against every segment, O(n·m) over the two transcripts.
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
