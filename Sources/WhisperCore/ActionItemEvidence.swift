import Foundation

/// Links each action item back to the transcript moment that best supports it — entirely locally, with
/// no model call (F177). For each item it picks the timestamped segment that shares the most *content
/// words* with the item text, and attaches that segment's text as the `quote` and its start as the
/// `timestamp`. Items with no confident match keep `quote`/`timestamp` nil, so "Play source" is only
/// offered where there is real evidence. User-entered fields (done/owner/due) are always preserved.
public enum ActionItemEvidence {
    /// Minimum shared content words for a segment to count as supporting evidence — two, so a single
    /// incidental word ("meeting", "team") can't create a spurious link.
    static let minimumSharedWords = 2

    public static func resolved(
        _ items: [ActionItem],
        segments: [TranscriptSegment]
    ) -> [ActionItem] {
        // Precompute each timestamped segment's content-word set once.
        let candidates: [(index: Int, start: Double, words: Set<String>, text: String)] = segments
            .enumerated()
            .compactMap { index, segment in
                guard let start = segment.start else { return nil }
                return (index, start, contentWords(segment.text), segment.text)
            }
        guard !candidates.isEmpty else { return items }

        return items.map { item in
            let itemWords = contentWords(item.text)
            guard !itemWords.isEmpty else { return cleared(item) }

            var best: (score: Int, start: Double, text: String, order: Int)?
            for candidate in candidates {
                let score = itemWords.intersection(candidate.words).count
                guard score >= minimumSharedWords else { continue }
                // Highest overlap wins; ties go to the earlier segment (stable, chronological).
                if score > (best?.score ?? 0) {
                    best = (score, candidate.start, candidate.text, candidate.index)
                }
            }

            var resolved = item
            if let best {
                resolved.quote = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
                resolved.timestamp = best.start
            } else {
                resolved.quote = nil
                resolved.timestamp = nil
            }
            return resolved
        }
    }

    /// An item with any stale evidence cleared (used when it has no matchable words).
    private static func cleared(_ item: ActionItem) -> ActionItem {
        var copy = item
        copy.quote = nil
        copy.timestamp = nil
        return copy
    }

    /// Words a match should key on: lowercased, alphanumeric-normalized (CJK-safe — ideographs are
    /// alphanumeric), at least two characters, and not a common filler word.
    static func contentWords(_ text: String) -> Set<String> {
        let tokens = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        return Set(tokens)
    }

    /// A deliberately small English filler set — enough to stop matches keying on connective words,
    /// without pretending to be a full stoplist (the two-word floor does most of the work).
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "will", "shall", "should", "would", "could",
        "are", "was", "were", "has", "have", "had", "you", "your", "our", "their", "they", "them",
        "his", "her", "its", "from", "into", "onto", "about", "over", "than", "then", "them",
        "who", "what", "when", "where", "which", "some", "any", "all", "not", "but", "get",
        "need", "needs", "to", "of", "in", "on", "at", "by", "up", "we", "he", "she", "it",
    ]
}
