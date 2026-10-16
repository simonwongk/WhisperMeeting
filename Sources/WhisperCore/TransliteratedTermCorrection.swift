import Foundation

/// Puts a Business Vocabulary term back into Chinese characters where a recognizer wrote part of it
/// in pinyin (F768).
///
/// F628 measured Qwen writing the spoken 王老师 as "Wang老师" in both decode paths, and F589 recorded
/// the same from Whisper Turbo. Refinement cannot repair it (F631: the model translated the line
/// instead), and Qwen takes no vocabulary prompt. The user decided on 2026-10-16 (relayed by
/// whisper-dfd4 and recorded on the ticket): correct it, but only for a term in Business
/// Vocabulary, and only where the pinyin is the characters' own sound; everything else stays as
/// heard.
///
/// So a span is replaced by a term only when all of these hold:
///
/// - the term is written entirely in Han characters, at least two of them;
/// - the span spells the term with a run of its characters at the start, or at the end, written as
///   their toneless pinyin, and the rest written as the characters themselves — at least one
///   character stays a character, so a name written wholly in Latin ("Wang", which is also an
///   English surname) is never touched;
/// - each pinyin syllable is exactly that character's reading (`MandarinSound.reading`, Foundation's
///   own transform), compared without case — a near sound is not enough here, because nothing but
///   the sound ties the Latin to the term;
/// - the pinyin is not part of a longer Latin word ("Swang老师" is left alone).
///
/// Syllables may be joined or separated by one space or hyphen, and one space may separate the
/// pinyin from the characters ("Wang 老师"). A polyphonic character gets one reading from the
/// transform, which can only miss a match, never invent one.
public enum TransliteratedTermCorrection {
    public static func corrected(_ text: String, terms: [String]) -> String {
        guard text.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) else { return text }
        var cache: [Character: String] = [:]
        var result = text
        // Longer terms first, so 王老师 is placed before a shorter term inside it could be.
        let candidates = Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        for term in candidates {
            let characters = Array(term)
            guard characters.count >= 2 else { continue }
            let readings = characters.map { MandarinSound.reading($0, cache: &cache) }
            guard readings.allSatisfy({ $0 != nil }) else { continue }
            let syllables = readings.compactMap { $0 }
            for pattern in patterns(characters: characters, syllables: syllables) {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(
                    in: result, options: [], range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: term)
                )
            }
        }
        return result
    }

    /// One pattern per way of writing a leading or trailing run of the term in pinyin.
    private static func patterns(characters: [Character], syllables: [String]) -> [String] {
        let joiner = "[ \\-]?"
        let notLatinBefore = "(?<![A-Za-z0-9])"
        let notLatinAfter = "(?![A-Za-z0-9])"
        func pinyin(_ range: Range<Int>) -> String {
            syllables[range].map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: joiner)
        }
        func literal(_ range: Range<Int>) -> String {
            NSRegularExpression.escapedPattern(for: String(characters[range]))
        }
        let count = characters.count
        var patterns: [String] = []
        for split in 1..<count {
            // Pinyin first: "Wang老师".
            patterns.append(notLatinBefore + pinyin(0..<split) + " ?" + literal(split..<count))
            // Pinyin last: "小Wang".
            patterns.append(literal(0..<split) + " ?" + pinyin(split..<count) + notLatinAfter)
        }
        return patterns
    }
}
