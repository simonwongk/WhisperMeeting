import Foundation

/// The single definition of "still the same Latin/alphanumeric token" shared by every place that
/// must recognise a term, or a replacement rule's `heard` phrase, as a *whole* occurrence rather
/// than a fragment of a larger word: `ProtectedTerms.contains` (F245/F534, main `03247a1`) and
/// `ReplacementBoundary` (F444, main `f969c1a`).
///
/// Before F592 these were two independently written character predicates — `ProtectedTerms`'s
/// `NSRegularExpression` class `[A-Za-z0-9_]` and `ReplacementBoundary`'s
/// `character.isLetter || character.isNumber` (CJK exempted) — and they disagreed on two inputs a
/// review found (an underscore neighbour; a non-Han Unicode letter neighbour such as Cyrillic,
/// Greek, Hangul or Kana), plus more this ticket pinned down explicitly (full-width Latin). This
/// type is the merge: `ProtectedTerms`'s regex class (`03247a1`), kept as the source of truth
/// because it was the one written with a documented reason for exactly which characters it
/// contains (its own comment: "a Latin letter, digit, or underscore"), while `ReplacementBoundary`
/// (`f969c1a`) was "written without sight of F534's regex" (F592's own filing) and is the one
/// brought into line.
///
/// The class is **ASCII letters and digits, underscore, and the Latin letters of four Unicode
/// blocks (below)** — nothing from any other script. WhisperMeet transcribes English or Mandarin
/// only (`docs/PRODUCT_SPEC.md`); Cyrillic/Greek/Hangul/Kana never appear glued to a Latin term in a
/// real transcript, so there is no real-world case that decision costs — but a token boundary still
/// needs one answer, and "not in the Latin alphabet" is the same answer this codebase already gives
/// a CJK neighbour: a boundary. A full-width Latin letter (e.g. "Ｋ") is outside those blocks and is
/// a boundary too, even though F590 made full-width/half-width *equivalent* for search matching; a
/// token boundary and a search match are different questions, and F590 never touched this file.
///
/// F592 drew the line at ASCII, which was wrong for the Latin letters outside it: English
/// transcripts carry accented names and loanwords (Jonás, Zoë, café, résumé) as Cyrillic text does
/// not, and "jon → Jonathan" turned "Jonás" into "Jonathanás" once F858 let replacement rules reach
/// capitalised names (the Wave 5 review of F858, T3). The Latin-1 Supplement's letters, Latin
/// Extended-A and -B and Latin Extended Additional now continue a token; every other script —
/// Cyrillic and full-width forms included — is still a boundary, exactly as F592 decided. A letter
/// written as a base letter plus a separate combining accent (decomposed) is one `Character` of
/// several scalars and is still a boundary here, as before; `ProtectedTerms` composes text before
/// it matches, so only `ReplacementBoundary` would see one.
public enum LatinTokenBoundary {
    /// The Latin letters outside ASCII, as scalar ranges: the Latin-1 Supplement's letters (U+00C0
    /// to U+00FF without × and ÷), Latin Extended-A and -B, and Latin Extended Additional.
    static let nonASCIILatinLetters: [ClosedRange<UInt32>] = [0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF]

    /// The character class an `NSRegularExpression` negative-lookaround spells as `[A-Za-z0-9_…]`.
    /// Built from the same ranges `isConnector` reads, so `ProtectedTerms`'s regex pattern and
    /// `isConnector`'s `Character` check are provably the same class, not two copies that could drift
    /// apart the way this ticket found.
    public static let regexCharacterClass = "A-Za-z0-9_" + nonASCIILatinLetters.map { range in
        "\\x{\(String(range.lowerBound, radix: 16))}-\\x{\(String(range.upperBound, radix: 16))}"
    }.joined()

    /// Whether `character` continues an existing Latin/alphanumeric token rather than ending it.
    /// True for an ASCII letter, an ASCII digit, an underscore, or one of the Latin letters outside
    /// ASCII — the set `regexCharacterClass` spells as a regex class. Every other character (space,
    /// punctuation, a CJK ideograph, a letter of another script, a full-width Latin letter or digit)
    /// is a boundary.
    public static func isConnector(_ character: Character) -> Bool {
        if character.isASCII { return character.isLetter || character.isNumber || character == "_" }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return nonASCIILatinLetters.contains { $0.contains(scalar.value) }
    }
}
