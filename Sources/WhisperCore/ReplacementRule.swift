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
        segments: [TranscriptSegment],
        evidence: CJKWordEvidence = .none
    ) -> [GlossaryCorrection] {
        let asCorrections = rules.map { TranscriptCorrection(from: $0.heard, to: $0.preferred) }
        return TranscriptCorrection.glossaryCorrections(from: asCorrections, segments: segments, evidence: evidence)
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
/// CJK terms are exempt from the Latin whole-token check, mirroring `ProtectedTerms`
/// (`Sources/WhisperCore/ProtectedTerms.swift`, F245): Chinese has no space between words, so the
/// character next to `heard` says nothing about whether it starts a new word, and treating every CJK
/// neighbour as "still the same token" would make a CJK rule impossible to ever apply. Failure 1's
/// fix still protects a CJK rule whose `preferred` contains its `heard`. The CJK-detection helper
/// (`hasCJK` below) stays a separate, local copy of `ProtectedTerms`'s (it is `private` there); the
/// *connector* check is shared, see below.
///
/// **A CJK occurrence gets its word edges from `CJKWordEvidence` instead (F594).** Without it,
/// 会议 → 会议室 also rewrote the 会议 inside 整理会议纪要 — failure 2, for Chinese. `WhisperCore`
/// cannot segment Chinese itself, so the caller supplies what can, and an occurrence is refused when
/// either says it is part of a longer word:
///
/// - **the segmenter** reports a word that starts before the occurrence and ends inside it, or starts
///   inside it and ends after it — the occurrence cuts that word (会议 in 会议厅, which NLTokenizer
///   keeps whole). An occurrence spanning several whole words cuts nothing, and neither does a gap
///   the segmenter reports no word for (whitespace, punctuation);
/// - **a known term** longer than `heard` and containing it occurs around it (会议 in 会议纪要 when
///   会议纪要 is in the user's vocabulary). Only this one sees a phrasal compound: NLTokenizer splits
///   会议纪要 into 会议 | 纪要, which was measured before any of this was written.
///
/// With `.none` (no segmenter, no known terms) a CJK occurrence is judged exactly as it was before
/// F594. A Latin occurrence ignores the evidence entirely: it already has F444's boundary.
///
/// A CJK neighbour also does not block a LATIN `heard`, and deliberately does not use the classic
/// `\b` regex boundary for that: `\b` treats Han ideographs as word characters (confirmed against
/// `NSRegularExpression`, not assumed — `\bKestrel\b` does not match inside "法輪功Kestrel測試"), so a
/// Latin term glued directly to CJK text with no space — common in Chinese meetings — would never
/// be recognised as a whole word at all. Here, a neighbour blocks the match only when the neighbour
/// is ITSELF a Latin letter or digit, so a CJK neighbour (or punctuation, space, or the string's
/// edge) always counts as a boundary — via `LatinTokenBoundary`, shared with `ProtectedTerms` since
/// F592 (this file's own connector check used to be a second, independently-written predicate that
/// disagreed with `ProtectedTerms`'s on an underscore neighbour and on a non-Han Unicode letter
/// neighbour; see `LatinTokenBoundary`'s doc comment for which definition won and why).
final class ReplacementBoundary {
    let heard: String
    let preferred: String
    private let evidence: CJKWordEvidence
    /// The known terms that could enclose a CJK occurrence of `heard`, worked out on first need: with
    /// hundreds of rules and a 5,000-term vocabulary, a scan per rule that never matches is waste.
    private var enclosingTermsCache: [String]?

    init(heard: String, notCoveredBy preferred: String, evidence: CJKWordEvidence = .none) {
        self.heard = heard
        self.preferred = preferred
        self.evidence = evidence
    }

    /// Whether `heard` genuinely occurs in `text` (see the type's documentation).
    static func occurs(
        _ heard: String, notCoveredBy preferred: String, in text: String, evidence: CJKWordEvidence = .none
    ) -> Bool {
        firstRange(of: heard, notCoveredBy: preferred, in: text, evidence: evidence) != nil
    }

    /// The first range in `text` where `heard` is a genuine occurrence, or `nil` if there is none.
    static func firstRange(
        of heard: String, notCoveredBy preferred: String, in text: String, evidence: CJKWordEvidence = .none
    ) -> Range<String.Index>? {
        ReplacementBoundary(heard: heard, notCoveredBy: preferred, evidence: evidence)
            .firstRange(in: SegmentedText(text, segmenter: evidence.segmenter))
    }

    /// The first genuine occurrence of `heard` in the segmented text. The text carries its own word
    /// ranges, so one segmentation serves every rule checked against the same segment.
    func firstRange(in segmented: SegmentedText) -> Range<String.Index>? {
        guard !heard.isEmpty else { return nil }
        let text = segmented.text
        let preferredRanges = preferred.isEmpty ? [] : Self.allRanges(of: preferred, in: text)
        var searchStart = text.startIndex
        while let candidate = text.range(of: heard, range: searchStart..<text.endIndex) {
            let coveredByPreferred = preferredRanges.contains {
                $0.contains(candidate.lowerBound) && candidate.upperBound <= $0.upperBound
            }
            if !coveredByPreferred, isWholeWord(candidate, in: segmented) {
                return candidate
            }
            searchStart = text.index(after: candidate.lowerBound)
        }
        return nil
    }

    /// Every (possibly overlapping) range where `needle` occurs in `text`. Overlap-permissive on
    /// purpose: over-covering with `preferred` is the safe direction, since it can only make the
    /// matcher skip more, never propose a wrong replacement.
    static func allRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = text.index(after: found.lowerBound)
        }
        return ranges
    }

    /// Whether the match at `range` is a whole word rather than part of a longer one: F444's Latin
    /// token rule for a Latin occurrence, the caller's evidence for a CJK one (F594).
    private func isWholeWord(_ range: Range<String.Index>, in segmented: SegmentedText) -> Bool {
        let text = segmented.text
        guard !Self.hasCJK(text[range]) else {
            return !segmented.cutsAWord(range) && !liesInsideAKnownTerm(range, in: text)
        }
        if range.lowerBound > text.startIndex, LatinTokenBoundary.isConnector(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, LatinTokenBoundary.isConnector(text[range.upperBound]) {
            return false
        }
        return true
    }

    /// Whether a known term longer than `heard` occurs around `range` — 会议 inside 会议纪要.
    private func liesInsideAKnownTerm(_ range: Range<String.Index>, in text: String) -> Bool {
        enclosingTerms().contains { term in
            Self.allRanges(of: term, in: text).contains {
                $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound && $0 != range
            }
        }
    }

    private func enclosingTerms() -> [String] {
        if let enclosingTermsCache { return enclosingTermsCache }
        let terms = evidence.knownTerms.filter { term in
            term.count > heard.count && Self.hasCJK(term) && term.contains(heard)
        }
        enclosingTermsCache = terms
        return terms
    }

    /// Same ranges `ProtectedTerms.hasCJK` checks (F245) — duplicated rather than shared, because
    /// that one is `private` to its own file; this is a plain Unicode CJK-ideograph range check,
    /// unlikely to need to change independently. (The *connector* check this file used to keep
    /// alongside it, `isLatinConnector`, is no longer a second copy — F592 moved it to
    /// `LatinTokenBoundary`, shared with `ProtectedTerms`.)
    static func hasCJK(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

/// One segment's text and the word ranges a segmenter finds in it, segmented at most once however
/// many phrases are checked against it (F594).
final class SegmentedText {
    let text: String
    private let segmenter: CJKWordEvidence.Segmenter?
    private var words: [Range<String.Index>]?

    init(_ text: String, segmenter: CJKWordEvidence.Segmenter?) {
        self.text = text
        self.segmenter = segmenter
    }

    /// Whether a word the segmenter found starts or ends strictly inside `range` while reaching
    /// beyond it — `range` cuts that word. With no segmenter nothing is cut.
    func cutsAWord(_ range: Range<String.Index>) -> Bool {
        guard let segmenter else { return false }
        let found = words ?? segmenter(text)
        words = found
        return found.contains { word in
            (word.lowerBound < range.lowerBound && range.lowerBound < word.upperBound)
                || (word.lowerBound < range.upperBound && range.upperBound < word.upperBound)
        }
    }
}
