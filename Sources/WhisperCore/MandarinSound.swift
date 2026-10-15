import Foundation

/// Whether two Chinese characters sound the same, ignoring tone (F536).
///
/// Correct Toward Vocabulary proposes a Chinese window that differs from a term in a minority of its
/// characters. Position alone cannot tell a mishearing from a different word: 张经里 for 张经理 is a
/// mishearing, 王经理 is someone else, and both match two of three characters in place. The review of
/// F536 measured seven wrong, pre-ticked proposals in eight ordinary sentences from that rule alone.
/// A speech recognizer substitutes a character for one that sounds alike, so every character a
/// window gets wrong must be a homophone of the term's — 里 and 理 are both "li"; 王 is "wang" and
/// 张 is "zhang".
///
/// The reading comes from Foundation's own transform (`.mandarinToLatin`, then `.stripDiacritics`),
/// so `WhisperCore` stays Foundation-only. A polyphonic character gets one reading from it, which can
/// only make two characters look different that might sound alike — a missed mishearing, never an
/// invented one.
///
/// **Nearly the same counts too (F916).** 预算 (yu suan) heard as 预选 (yu xuan) — F817's own
/// example, which equal readings could not match — and the confusions of some accents: the
/// retroflex merger (zh/z, ch/c, sh/s), s for x, n for l, and the front and back nasals (in/ing,
/// en/eng). Two readings are compared after each is folded to one spelling of its class
/// (`canonicalReading`): the table is those six pairs and no more — an/ang is left out, as the
/// ticket left it out, and every pair widens the net for other words that sound nearly alike. Its
/// cost was measured on the Wave 5 review's 40 everyday sentences before it shipped (the F916
/// closure in `docs/TICKET_LOG.md`).
enum MandarinSound {
    /// True when `heard` and `meant` are both Han characters with the same toneless reading, or
    /// readings that differ only within the table above. Anything else — a digit, a Latin letter,
    /// punctuation — is a different sound unless identical.
    static func isHomophone(_ heard: Character, of meant: Character, cache: inout [Character: String]) -> Bool {
        guard heard != meant else { return true }
        guard let a = reading(heard, cache: &cache), let b = reading(meant, cache: &cache) else { return false }
        return canonicalReading(a) == canonicalReading(b)
    }

    /// Pinyin initials, the two-letter ones first so "zh" is not read as "z" + "h".
    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]

    /// `reading` with its initial and final each folded to one spelling of its confusion class
    /// (F916): zh → z, ch → c, sh and x → s, n → l; a final in -ing → -in, in -eng → -en. A reading
    /// with no initial ("er", "ai") keeps its final.
    static func canonicalReading(_ reading: String) -> String {
        var initial = ""
        var final = reading
        if let found = initials.first(where: { reading.hasPrefix($0) }) {
            initial = found
            final = String(reading.dropFirst(found.count))
        }
        switch initial {
        case "zh": initial = "z"
        case "ch": initial = "c"
        case "sh", "x": initial = "s"
        case "n": initial = "l"
        default: break
        }
        if final.hasSuffix("ing") {
            final = String(final.dropLast(3)) + "in"
        } else if final.hasSuffix("eng") {
            final = String(final.dropLast(3)) + "en"
        }
        return initial + final
    }

    /// The toneless Latin reading of a Han character, or nil for anything else.
    static func reading(_ character: Character, cache: inout [Character: String]) -> String? {
        guard ReplacementBoundary.hasCJK(String(character)) else { return nil }
        if let known = cache[character] { return known }
        let text = String(character)
        guard let latin = text.applyingTransform(.mandarinToLatin, reverse: false),
              let plain = latin.applyingTransform(.stripDiacritics, reverse: false)?.lowercased(),
              plain != text, !plain.isEmpty else { return nil }
        cache[character] = plain
        return plain
    }
}
