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
        for sentence in sentences {
            let target = alignmentKey(sentence)
            guard !target.isEmpty, itemIndex < alignedItems.count else { return [] }
            let firstIndex = itemIndex
            var assembled = ""

            while itemIndex < alignedItems.count, assembled.count < target.count {
                assembled += alignmentKey(alignedItems[itemIndex].text)
                guard target.hasPrefix(assembled) else { return [] }
                itemIndex += 1
            }
            guard assembled == target else { return [] }

            let first = alignedItems[firstIndex]
            let last = alignedItems[itemIndex - 1]
            result.append(TranscriptSegment(
                speaker: nil,
                start: first.start,
                end: last.end,
                text: sentence
            ))
        }

        guard itemIndex == alignedItems.count else { return [] }
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

    private static func alignmentKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
