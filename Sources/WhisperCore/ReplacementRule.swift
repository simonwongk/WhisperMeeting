import Foundation

/// A user-defined exact replacement: whenever `heard` appears in a transcript, propose replacing it
/// with `preferred` (F179). Unlike the near-miss `GlossaryCorrector`, this is an *exact* rule the user
/// knows recurs — persisted alongside the business vocabulary. It only ever proposes; the user reviews
/// every proposal before it applies, and the recording is never touched.
public struct ReplacementRule: Codable, Sendable, Equatable, Hashable {
    public let heard: String
    public let preferred: String

    public init(heard: String, preferred: String) {
        self.heard = heard
        self.preferred = preferred
    }
}

/// Turns exact replacement rules into reviewable `GlossaryCorrection`s over a transcript's segments
/// (F179), reusing the same mapping as F165's LLM corrections so rule-based fixes flow through the
/// identical F82 review sheet + `GlossaryCorrector.apply` path (which never opens the audio).
/// Boundary-aware exact match (F444, see `ReplacementBoundary` below) — one correction per segment
/// that contains a genuine occurrence of `heard`; no-op and empty rules are dropped.
public enum ReplacementRuleMatcher {
    public static func corrections(
        rules: [ReplacementRule],
        segments: [TranscriptSegment]
    ) -> [GlossaryCorrection] {
        let asCorrections = rules.map { TranscriptCorrection(from: $0.heard, to: $0.preferred) }
        return TranscriptCorrection.glossaryCorrections(from: asCorrections, segments: segments)
    }
}

/// Boundary-aware matching for exact `heard → preferred` replacement rules and their F165 LLM
/// sibling (`TranscriptCorrection`). Used by both the matcher
/// (`TranscriptCorrection.glossaryCorrections`, `LocalTranscriptCorrector.swift`) and the applier
/// (`GlossaryCorrector.apply`), so a proposal and its application can never disagree about which
/// occurrence was meant (F444).
///
/// Two failures, one root cause — a plain substring test does not know where a word ends:
///
/// 1. **A rule's own `preferred` text swallows it.** "Jon → Jonathan" is also a plain substring of
///    the word "Jonathan", so a segment that already reads "Jonathan" proposed correcting the "Jon"
///    inside it — and applying that proposal (which replaced the FIRST occurrence of "Jon" in the
///    segment) could rewrite an unrelated, already-correct "Jon" earlier in the same line while
///    leaving the real mis-hearing untouched. This is the ticket's cited scenario: 'Thanks Jonathan,
///    and Jon agrees.' proposed two identical-looking rows for one rule.
/// 2. **An unrelated word gets clipped.** The same substring test also matches "Jon" inside "Jones",
///    which has nothing to do with `preferred` at all.
///
/// The fix: skip any occurrence of `heard` that lies inside an occurrence of `preferred` (kills
/// failure 1, any script), and additionally require a Latin/alphanumeric `heard` to be a WHOLE
/// token — not immediately flanked by another Latin letter or digit (kills failure 2).
///
/// CJK terms are deliberately exempted from the whole-token check, mirroring `ProtectedTerms`
/// (`Sources/WhisperCore/ProtectedTerms.swift`, F245 — read for the rationale, not imported: F534 is
/// changing that file's containment rule in parallel, so this is a separate, small check kept local
/// to the rules matcher). Chinese has no space between words, so nothing short of a segmenter can
/// tell whether a CJK character next to `heard` starts a new word or continues the same one, and
/// treating every CJK neighbour as "still the same token" would make a CJK rule impossible to ever
/// apply. Failure 1's fix still protects a CJK rule whose `preferred` contains its `heard`.
///
/// A CJK neighbour also does not block a LATIN `heard`, and deliberately does not use the classic
/// `\b` regex boundary for that: `\b` treats Han ideographs as word characters (confirmed against
/// `NSRegularExpression`, not assumed — `\bKestrel\b` does not match inside "法輪功Kestrel測試"), so a
/// Latin term glued directly to CJK text with no space — common in Chinese meetings — would never
/// be recognised as a whole word at all. Here, a neighbour blocks the match only when the neighbour
/// is ITSELF a Latin letter or digit, so a CJK neighbour (or punctuation, space, or the string's
/// edge) always counts as a boundary.
enum ReplacementBoundary {
    /// Whether `heard` genuinely occurs in `text` (see the type's documentation).
    static func occurs(_ heard: String, notCoveredBy preferred: String, in text: String) -> Bool {
        firstRange(of: heard, notCoveredBy: preferred, in: text) != nil
    }

    /// The first range in `text` where `heard` is a genuine occurrence, or `nil` if there is none.
    static func firstRange(of heard: String, notCoveredBy preferred: String, in text: String) -> Range<String.Index>? {
        guard !heard.isEmpty else { return nil }
        let preferredRanges = preferred.isEmpty ? [] : allRanges(of: preferred, in: text)
        var searchStart = text.startIndex
        while let candidate = text.range(of: heard, range: searchStart..<text.endIndex) {
            let coveredByPreferred = preferredRanges.contains {
                $0.contains(candidate.lowerBound) && candidate.upperBound <= $0.upperBound
            }
            if !coveredByPreferred, isWholeToken(candidate, in: text) {
                return candidate
            }
            searchStart = text.index(after: candidate.lowerBound)
        }
        return nil
    }

    /// Every (possibly overlapping) range where `needle` occurs in `text`. Overlap-permissive on
    /// purpose: over-covering with `preferred` is the safe direction, since it can only make the
    /// matcher skip more, never propose a wrong replacement.
    private static func allRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = text.index(after: found.lowerBound)
        }
        return ranges
    }

    /// Whether the match at `range` is a whole token rather than a fragment of a larger Latin run.
    /// CJK occurrences are exempt — see the type's documentation.
    private static func isWholeToken(_ range: Range<String.Index>, in text: String) -> Bool {
        guard !hasCJK(text[range]) else { return true }
        if range.lowerBound > text.startIndex, isLatinConnector(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isLatinConnector(text[range.upperBound]) {
            return false
        }
        return true
    }

    /// A neighbour that would extend a Latin/alphanumeric run: a letter or digit that is not itself
    /// CJK. Punctuation, whitespace, the string's edge, and any CJK character all count as a
    /// boundary instead.
    private static func isLatinConnector(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        return !hasCJK(String(character))
    }

    /// Same ranges `ProtectedTerms.hasCJK` checks (F245) — duplicated rather than shared, because
    /// that one is `private` to its own file and F534 is changing its containment rule concurrently;
    /// this is a plain Unicode CJK-ideograph range check, unlikely to need to change independently.
    private static func hasCJK(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}
