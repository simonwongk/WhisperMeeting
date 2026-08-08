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

    /// Tokens a match keys on. Space-delimited scripts (English) tokenize into whole words (≥2 chars,
    /// non-filler); space-free scripts (Chinese) have no word boundaries, so a run of ideographs
    /// tokenizes into overlapping **character bigrams** — otherwise a whole Chinese item would collapse
    /// to a single token and never meet the two-token overlap floor, and Mandarin is a first-class
    /// supported language. A lone ideograph is kept as a one-character token.
    static func contentWords(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            if latin.count >= 2, !stopwords.contains(latin) { tokens.insert(latin) }
            latin = ""
        }
        func flushCJK() {
            if cjk.count == 1 {
                tokens.insert(String(cjk[0]))
            } else if cjk.count >= 2 {
                for i in 0..<(cjk.count - 1) {
                    tokens.insert(String(cjk[i]) + String(cjk[i + 1]))
                }
            }
            cjk = []
        }

        for character in text.lowercased() {
            if let scalar = character.unicodeScalars.first,
               character.unicodeScalars.count == 1,
               isCJKIdeograph(scalar) {
                flushLatin()
                cjk.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                latin.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return tokens
    }

    /// Whether a scalar is a CJK ideograph (Chinese/Japanese/Korean Han), which has no word spacing —
    /// the blocks that back WhisperMeet's supported Mandarin transcripts.
    static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0x20000...0x2FA1F:  // CJK Extension B+ and compatibility supplement
            return true
        default:
            return false
        }
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
