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
enum MandarinSound {
    /// True when `heard` and `meant` are both Han characters with the same toneless reading.
    /// Anything else — a digit, a Latin letter, punctuation — is a different sound unless identical.
    static func isHomophone(_ heard: Character, of meant: Character, cache: inout [Character: String]) -> Bool {
        guard heard != meant else { return true }
        guard let a = reading(heard, cache: &cache), let b = reading(meant, cache: &cache) else { return false }
        return a == b
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
