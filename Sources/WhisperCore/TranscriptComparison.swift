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
        primary.map { segment in
            guard let match = secondary.first(where: { aligns(segment, $0) }) else {
                return TranscriptComparisonSpan(
                    kind: .nonOverlapping, start: segment.start,
                    primaryText: segment.text, secondaryText: nil
                )
            }
            let same = normalize(segment.text) == normalize(match.text)
            return TranscriptComparisonSpan(
                kind: same ? .agree : .diverge, start: segment.start,
                primaryText: segment.text, secondaryText: match.text
            )
        }
    }

    /// Two segments align when their time spans overlap; if a side lacks timestamps, fall back to a
    /// normalized-text match so a timestamp-less (e.g. unaligned Qwen) transcript can still compare.
    private static func aligns(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
        if let aStart = a.start, let aEnd = a.end, let bStart = b.start, let bEnd = b.end {
            return aStart < bEnd && bStart < aEnd
        }
        return normalize(a.text) == normalize(b.text)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
