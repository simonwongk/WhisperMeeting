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
///   their toneless pinyin, joined straight to the rest written as the characters themselves — at
///   least one character stays a character, so a name written wholly in Latin ("Wang", which is
///   also an English surname) is never touched, and no space may separate the scripts (every
///   recorded recognizer output joins them, and a space is where an English word beside Han sits:
///   "I need a 里程碑", review finding 1);
/// - each pinyin syllable is exactly that character's reading (`MandarinSound.reading`, Foundation's
///   own transform), compared without case — a near sound is not enough here, because nothing but
///   the sound ties the Latin to the term;
/// - a run of one syllable is not also a common English word (`PinyinEnglishWords`, derived by
///   `Scripts/generate-pinyin-english-words.swift`): "you先说吧" is English beside 先说吧, not 优先;
/// - the pinyin is not part of a longer word in any Latin script ("Swang老师", "éwang老师"), and
///   no digit touches it;
/// - no other vocabulary term with different characters claims the same or an overlapping span:
///   with 王老师 and 汪老师 both in the vocabulary, "Wang老师" cannot say which was meant, so it stays
///   as heard (review finding 3). A term whose span strictly contains another's is not ambiguous —
///   the longer term wins.
///
/// Syllables of a multi-syllable run may be joined or separated by one space or hyphen ("Zhang
/// San丰"). A polyphonic character gets one reading from the transform, which can only miss a match,
/// never invent one.
public enum TransliteratedTermCorrection {
    public static func corrected(_ text: String, terms: [String]) -> String {
        guard text.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) else { return text }
        var cache: [Character: String] = [:]
        var matches: [(range: NSRange, term: String)] = []
        let whole = NSRange(text.startIndex..., in: text)
        for term in Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            let characters = Array(term)
            // At least one of the term's characters stays a character in any span this replaces,
            // so a term none of whose characters is in the text is skipped before any reading or
            // pattern is built — a vocabulary of hundreds of terms costs a scan, not hundreds of
            // regular expressions.
            guard characters.count >= 2, characters.contains(where: { text.contains($0) }) else { continue }
            let readings = characters.map { MandarinSound.reading($0, cache: &cache) }
            guard readings.allSatisfy({ $0 != nil }) else { continue }
            let syllables = readings.compactMap { $0 }
            for pattern in patterns(characters: characters, syllables: syllables) {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }
                for match in expression.matches(in: text, range: whole) where !isAcronym(match.range, in: text) {
                    matches.append((match.range, term))
                }
            }
        }
        let accepted = unambiguous(matches)
        guard !accepted.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: match.range, with: match.term)
        }
        return result as String
    }

    /// The matches no other term contests (finding 3), without overlaps: a match is dropped when a
    /// match of a different term strictly contains it (the longer term wins), or when a match of a
    /// different term has the same span or overlaps it partly (the vocabulary cannot say which name
    /// was meant). Of one term's overlapping matches, the longest is kept.
    private static func unambiguous(_ matches: [(range: NSRange, term: String)]) -> [(range: NSRange, term: String)] {
        func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
            NSIntersectionRange(outer, inner) == inner && outer != inner
        }
        func overlaps(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }
        let survivors = matches.filter { candidate in
            !matches.contains { other in
                guard overlaps(candidate.range, other.range) else { return false }
                if other.term == candidate.term { return contains(other.range, candidate.range) }
                return !contains(candidate.range, other.range)
            }
        }
        var chosen: [(range: NSRange, term: String)] = []
        for match in survivors where !chosen.contains(where: { overlaps($0.range, match.range) }) {
            chosen.append(match)
        }
        return chosen
    }

    /// Whether the match's Latin letters are two or more capitals and nothing else: an acronym
    /// ("AI芯片", "BI报表"), never a name — recognizers write names "Wang", not "WANG" (the round-2
    /// review's C6). "ai" is not in the English list, so only this rule keeps 小AI助手 as heard.
    private static func isAcronym(_ range: NSRange, in text: String) -> Bool {
        guard let span = Range(range, in: text) else { return false }
        let letters = text[span].unicodeScalars.filter { $0.properties.isAlphabetic && $0.isASCII }
        return letters.count >= 2 && letters.allSatisfy { $0.properties.isUppercase }
    }

    /// One pattern per way of writing a leading or trailing run of the term in pinyin.
    ///
    /// A run of one syllable that is also a common English word ("you", "ping", "yang") is matched
    /// only when it is written as a name — capitalised, "Yang", case-sensitively — and directly
    /// before Chinese characters: the user's decision of 2026-10-17 (recorded on F768). Round 2
    /// refused such a run everywhere, which left 12 of the round-2 review's 13 common surnames as
    /// heard (C7); the collisions round 2 fixed were all lowercase English ("you先说吧", "ping").
    private static func patterns(characters: [Character], syllables: [String]) -> [String] {
        let joiner = "[ \\-]?"
        // Not inside a longer word of a Latin script, and no digit beside it (finding 5).
        let notLatinBefore = "(?<![\\p{Latin}\\p{N}])"
        let notLatinAfter = "(?![\\p{Latin}\\p{N}])"
        /// The pattern for a run, and whether it is an English word that must be followed by Han.
        func pinyin(_ range: Range<Int>) -> (pattern: String, needsHanAfter: Bool) {
            if range.count == 1, PinyinEnglishWords.words.contains(syllables[range.lowerBound]) {
                let syllable = syllables[range.lowerBound]
                let name = syllable.prefix(1).uppercased() + syllable.dropFirst()
                return ("(?-i:" + NSRegularExpression.escapedPattern(for: name) + ")", true)
            }
            return (syllables[range].map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: joiner), false)
        }
        func literal(_ range: Range<Int>) -> String {
            NSRegularExpression.escapedPattern(for: String(characters[range]))
        }
        let count = characters.count
        var patterns: [String] = []
        for split in 1..<count {
            // Pinyin first: "Wang老师" — the characters follow it directly either way.
            let first = pinyin(0..<split)
            patterns.append(notLatinBefore + first.pattern + literal(split..<count))
            // Pinyin last: "小Wang"; an English-word run only when Chinese follows it ("小Yang呢").
            let last = pinyin(split..<count)
            patterns.append(literal(0..<split) + last.pattern + (last.needsHanAfter ? "(?=\\p{Han})" : notLatinAfter))
        }
        return patterns
    }
}
