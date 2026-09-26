import Foundation

/// The single definition of "still the same Latin/alphanumeric token" shared by every place that
/// must recognise a term, or a replacement rule's `heard` phrase, as a *whole* occurrence rather
/// than a fragment of a larger word: `ProtectedTerms.contains` (F245/F534) and `ReplacementBoundary`
/// (F444).
///
/// Before F592 these were two independently written character predicates — `ProtectedTerms`'s
/// `NSRegularExpression` class `[A-Za-z0-9_]` and `ReplacementBoundary`'s
/// `character.isLetter || character.isNumber` (CJK exempted) — and they disagreed on two inputs a
/// review found (an underscore neighbour; a non-Han Unicode letter neighbour such as Cyrillic,
/// Greek, Hangul or Kana), plus more this ticket pinned down explicitly (full-width Latin). This
/// type is the merge: `ProtectedTerms`'s regex class, kept as the source of truth because it was
/// the one written with a documented reason for exactly which characters it contains (its own
/// comment: "a Latin letter, digit, or underscore"), while `ReplacementBoundary` was "written
/// without sight of F534's regex" (F592's own filing) and is the one brought into line.
///
/// The class is deliberately **ASCII-only**. WhisperMeet transcribes English or Mandarin only
/// (`docs/PRODUCT_SPEC.md`); Cyrillic/Greek/Hangul/Kana never appear glued to a Latin term in a
/// real transcript, so there is no real-world case this decision costs — but a token boundary
/// still needs one answer, and "not in the Latin alphabet" is the same answer this codebase already
/// gives a CJK neighbour (which is not ASCII either): a boundary. A full-width Latin letter
/// (e.g. "Ｋ") is the same call for the same reason — it is not in `[A-Za-z0-9_]` either, so it is a
/// boundary too, even though F590 made full-width/half-width *equivalent* for search matching; a
/// token boundary and a search match are different questions, and F590 never touched this file.
public enum LatinTokenBoundary {
    /// The character class an `NSRegularExpression` negative-lookaround spells as `[A-Za-z0-9_]`.
    /// Kept as a string so `ProtectedTerms`'s regex pattern and `isConnector`'s `Character` check
    /// are provably the same class, not two copies that could drift apart the way this ticket found.
    public static let regexCharacterClass = "A-Za-z0-9_"

    /// Whether `character` continues an existing Latin/alphanumeric token rather than ending it.
    /// True only for an ASCII letter, an ASCII digit, or underscore — the same set
    /// `regexCharacterClass` spells as a regex class. Every other character (space, punctuation, a
    /// CJK ideograph, a non-Han Unicode letter, a full-width Latin letter or digit) is a boundary.
    public static func isConnector(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}
