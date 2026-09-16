import Foundation

public struct QwenAlignedItem: Codable, Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum QwenAlignedTranscript {
    /// Maps Qwen's word-level alignment back onto the model's punctuated transcript. If the two
    /// outputs cannot be matched exactly after punctuation/spacing normalization, this returns no
    /// segments so callers retain the complete original text instead of risking dropped words.
    public static func segments(
        fullText: String,
        alignedItems: [QwenAlignedItem]
    ) -> [TranscriptSegment] {
        let sentences = sentenceSlices(fullText)
        guard !sentences.isEmpty, !alignedItems.isEmpty else { return [] }

        var itemIndex = 0
        var result: [TranscriptSegment] = []
        var timedCount = 0

        for sentence in sentences {
            let target = alignmentKey(sentence)
            let firstIndex = itemIndex
            var assembled = ""
            var matched = false

            // Consume items until they spell this sentence, or until they diverge from it.
            // `itemIndex` always advances, which is what lets a LATER sentence re-sync after an
            // earlier one failed — the whole point of F263. The old loop rewound nothing and
            // returned `[]`, so one local mismatch cost every timestamp in the meeting.
            while !target.isEmpty, itemIndex < alignedItems.count {
                assembled += alignmentKey(alignedItems[itemIndex].text)
                itemIndex += 1
                if assembled == target {
                    matched = true
                    break
                }
                if !target.hasPrefix(assembled) { break }
            }

            if matched, itemIndex > firstIndex {
                result.append(TranscriptSegment(
                    speaker: nil,
                    start: alignedItems[firstIndex].start,
                    end: alignedItems[itemIndex - 1].end,
                    text: sentence
                ))
                timedCount += 1
            } else {
                // Untimed, and never inherited from a neighbour: a wrong timestamp seeks the user
                // to the wrong place in the audio, which is worse than having none. The text is
                // still verbatim, so the original "complete text preserved" guarantee holds.
                result.append(TranscriptSegment(speaker: nil, start: nil, end: nil, text: sentence))
            }
        }

        // Nothing reconciled at all — keep the pre-F263 contract exactly. `QwenASRClient`'s F30
        // warning and the caller's fallback to the raw transcript both key off an empty result, and
        // partial recovery must only ADD to that behaviour, never change it.
        guard timedCount > 0 else { return [] }
        return result
    }

    private static func sentenceSlices(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "\n"]
        var current = ""
        var result: [String] = []

        for character in text {
            current.append(character)
            if terminators.contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    result.append(sentence)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            result.append(remainder)
        }
        return result
    }

    /// Exactly the characters the aligner itself keeps, so the two sides can ever agree (F263).
    ///
    /// `qwen3_forced_aligner.py:23-30` (`is_kept_char`) keeps Unicode categories `L*` and `N*` plus
    /// an apostrophe, and `clean_token` strips everything else from the token text it reports. Swift's
    /// `CharacterSet.alphanumerics` is `L* + M* + N*`, so the old key retained combining marks the
    /// aligner had already removed — and no amount of assembling could then match. The apostrophe is
    /// dropped on both sides here, which is harmless because both sides go through this function.
    private static let keptScalars = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)

    private static func alignmentKey(_ text: String) -> String {
        // Compose first, so a decomposed "é" becomes one letter instead of a letter plus a mark that
        // the filter below would then discard — which would reintroduce the mismatch it prevents.
        String(
            text.precomposedStringWithCanonicalMapping
                .lowercased()
                .unicodeScalars
                .filter { keptScalars.contains($0) }
        )
    }
}
