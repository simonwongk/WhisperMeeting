import Foundation
import NaturalLanguage
import WhisperCore

/// The Chinese word segmenter behind `CJKWordEvidence` in the app (F594).
///
/// `WhisperCore` is Foundation-only (the purity rule, F372), so the replacement matchers there take
/// their word boundaries as a closure and this is the one the app passes: `NLTokenizer(unit: .word)`,
/// which segments Chinese with the system dictionary.
///
/// What it can and cannot see was measured before it was relied on (F594's closure entry): it keeps
/// a lexicalised compound whole (会议室, 会议厅, 数据库, 总经理, 客户端) but splits a phrasal one
/// (会议纪要 → 会议 | 纪要, 视频会议 → 视频 | 会议), and it never cut an intended word of the zh/cs
/// bench references. So it refuses a rule inside the first kind and not the second — the second is
/// what `CJKWordEvidence.knownTerms` (the user's vocabulary) is for.
enum NaturalLanguageWordSegmenter {
    /// The word ranges `NLTokenizer` finds in `text`, as ranges into `text` itself.
    ///
    /// A fresh tokenizer per call: `NLTokenizer` is not documented as safe to share across threads,
    /// and the Correct Toward Vocabulary pass calls this off the main actor.
    @Sendable
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        // The tokenizer reports ranges into its own copy of the string. Carry each one across by
        // UTF-16 offset rather than reuse the index, so a range is always valid in `text`.
        let tokenized = tokenizer.string ?? text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: tokenized.startIndex..<tokenized.endIndex) { range, _ in
            if let carried = Range(NSRange(range, in: tokenized), in: text) {
                ranges.append(carried)
            }
            return true
        }
        return ranges
    }
}
