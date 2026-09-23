import Foundation

extension TranscriptLanguage {
    /// The name the app uses for this language in a sentence — "Mandarin", as `LanguageConsistency`
    /// already says, not "Chinese".
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Mandarin"
        }
    }

    /// The language of one transcript line, judged by **words** (F424), or nil when the line has
    /// none or is an exact tie.
    ///
    /// `dominant(of:)` counts characters, which is right for a whole transcript and wrong for one
    /// line: an English word is several letters and a Chinese word one or two characters, so by
    /// characters "我们用 flash card 来复习" is English. Here each CJK ideograph is a word and each
    /// run of other letters is one word. Digits and punctuation are not words, so `操！` is Mandarin
    /// and "2026" is nothing. A tie has no answer rather than a guess, which keeps the line.
    ///
    /// Uses the same ideograph range as `dominant(of:)` and the Qwen helper, so the three agree on
    /// what a Mandarin character is.
    public static func ofLine(_ text: String) -> TranscriptLanguage? {
        var ideographs = 0
        var otherWords = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x3400 && scalar.value <= 0x9FFF {
                ideographs += 1
                inWord = false
            } else if scalar.properties.isAlphabetic {
                if !inWord { otherWords += 1 }
                inWord = true
            } else if inWord, scalar == "'" || scalar == "\u{2019}" {
                // "don't" is one word, not two.
                continue
            } else {
                inWord = false
            }
        }
        guard ideographs != otherWords else { return nil }
        return ideographs > otherWords ? .chinese : .english
    }
}

/// Picks the transcript lines spoken in a language the meeting is not in (F424) — a lecture's
/// side-conversation, typically. It only *picks*: removal is the caller's, after the user has seen
/// the list and confirmed it.
public enum TranscriptLanguageFilter {
    /// The meeting's language: its stored code when it has one ("en", "zh", "zh-CN"), otherwise the
    /// language most of its lines are in. Nil when neither says anything.
    public static func meetingLanguage(
        languageCode: String?,
        segments: [TranscriptSegment]
    ) -> TranscriptLanguage? {
        if let code = languageCode?.lowercased() {
            if code == "en" || code.hasPrefix("en-") { return .english }
            if code == "zh" || code.hasPrefix("zh-") { return .chinese }
        }
        var english = 0
        var chinese = 0
        for segment in segments {
            switch TranscriptLanguage.ofLine(segment.text) {
            case .english: english += 1
            case .chinese: chinese += 1
            case nil: break
            }
        }
        guard english != chinese else { return nil }
        return english > chinese ? .english : .chinese
    }

    /// Indices, in transcript order, of the lines whose language is known and is not `language`.
    /// A line with no language (`TranscriptLanguage.ofLine` is nil) is never picked.
    public static func indices(notIn language: TranscriptLanguage, segments: [TranscriptSegment]) -> [Int] {
        segments.indices.filter { index in
            guard let lineLanguage = TranscriptLanguage.ofLine(segments[index].text) else { return false }
            return lineLanguage != language
        }
    }
}
