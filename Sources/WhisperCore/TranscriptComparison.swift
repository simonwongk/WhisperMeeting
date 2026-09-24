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
            guard let match = counterpart(of: segment, normalized: text, in: secondary, secondaryTexts) else {
                return TranscriptComparisonSpan(
                    kind: .nonOverlapping, start: segment.start,
                    primaryText: segment.text, secondaryText: nil
                )
            }
            return TranscriptComparisonSpan(
                kind: match.same ? .agree : .diverge, start: segment.start,
                primaryText: segment.text, secondaryText: match.segment.text
            )
        }
    }

    /// The other engine's reading of `segment`, and whether it says the same thing (F472).
    ///
    /// Two segments align when their time spans overlap; if a side lacks timestamps, a
    /// normalized-text match stands in, so a timestamp-less (e.g. unaligned Qwen) passage can still
    /// compare. Of everything that aligns:
    ///
    /// - one that says the same thing wins — both engines did say it here, so the row agrees and
    ///   Replace is not offered;
    /// - otherwise the timed segment that overlaps it for the LONGEST time.
    ///
    /// This used to take the first segment that aligned at all. Two engines' boundaries routinely
    /// overlap by a fraction of a second, so that was usually the other engine's previous sentence,
    /// and Replace then wrote it over the line: the same sentence twice and the real line gone.
    /// Preferring agreement over overlap is the same caution — when in doubt, offer nothing to
    /// replace rather than a neighbour's words.
    private static func counterpart(
        of segment: TranscriptSegment,
        normalized text: String,
        in secondary: [TranscriptSegment],
        _ secondaryTexts: [String]
    ) -> (segment: TranscriptSegment, same: Bool)? {
        var longest: (segment: TranscriptSegment, overlap: Double)?
        for (candidate, candidateText) in zip(secondary, secondaryTexts) {
            if let overlap = sharedSeconds(segment, candidate) {
                guard overlap > 0 else { continue }
                if candidateText == text { return (candidate, true) }
                if longest.map({ overlap > $0.overlap }) ?? true { longest = (candidate, overlap) }
            } else if candidateText == text {
                return (candidate, true)
            }
        }
        return longest.map { ($0.segment, false) }
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

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
