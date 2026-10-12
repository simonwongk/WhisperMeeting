import Foundation

/// A user-defined exact replacement: whenever `heard` appears in a transcript, propose replacing it
/// with `preferred` (F179). Unlike the near-miss `GlossaryCorrector`, this is an *exact* rule the user
/// knows recurs — persisted alongside the business vocabulary. In a meeting's transcript it only ever
/// proposes; the user reviews every proposal before it applies, and the recording is never touched.
/// Quick Dictation applies the rules to its text before pasting, with no review (F821, the user's
/// decision of 2026-10-07): `ReplacementRuleMatcher.applied(_:to:evidence:)`.
///
/// "Exact" in its case, with one exception (F858): where it starts a sentence, `heard` also matches
/// with its first character upper-cased, because a recognizer capitalises the first word of a
/// sentence and a rule written "jon → Jonathan" is meant for that "Jon" too. The replacement keeps
/// the capital — see `ReplacementBoundary.replacement(for:)`. A capital anywhere else is left alone:
/// mid-sentence it is what tells the person Bill from the bill a rule "bill → invoice" was written
/// for, and Quick Dictation pastes with no review. So are ALL CAPS (JON), inner capitals (jOn), and a
/// rule written with a capital meeting the word in lower case. The user decided on 2026-10-12 (F913)
/// that a rule reaches sentence starts only; F938 narrowed what counts as one ("Mr. Bill" does not).
public struct ReplacementRule: Codable, Sendable, Equatable, Hashable {
    public let heard: String
    public let preferred: String

    public init(heard: String, preferred: String) {
        self.heard = heard
        self.preferred = preferred
    }
}

/// Turns exact replacement rules into reviewable `GlossaryCorrection`s over a transcript's segments
/// (F179), so rule-based fixes flow through the identical F82 review sheet + `GlossaryCorrector.apply`
/// path (which never opens the audio). Boundary-aware match (F444, see `ReplacementBoundary` below)
/// — one correction per segment that contains a genuine occurrence of `heard`, or of `heard` with a
/// capital first character where it starts a sentence (F858); no-op and empty rules are dropped.
public enum ReplacementRuleMatcher {
    /// Rule-major, then segment order, as when this mapped the rules through F165's
    /// `TranscriptCorrection.glossaryCorrections`. A proposal's `from` is the text as it stands in
    /// the segment ("Jon", for a rule written "jon") and its `to` carries that capital, so
    /// `GlossaryCorrector.apply`'s exact search finds it. It is proposed only where that search
    /// would apply it — the first occurrence `apply` finds must be this one — or a ticked proposal
    /// could change a different occurrence than the one reviewed (F444).
    ///
    /// For the same reason an occurrence gets one row however many rules reach it — the first rule's
    /// in list order, as in dictation, which applies the rules in that order. The store keeps
    /// "jon → Jonathan" and "Jon → Jonathan" as two rules, a sentence-initial "Jon" is an occurrence
    /// of both, and two rows for it, both ticked, changed the next "Jon" too; so did "bill → invoice"
    /// and "Bill → invoice", whose rows even differ ("Bill → Invoice" carries the sentence's capital,
    /// "Bill → invoice" does not). A row whose occurrence overlaps one already proposed in its segment
    /// is dropped.
    public static func corrections(
        rules: [ReplacementRule],
        segments: [TranscriptSegment],
        evidence: CJKWordEvidence = .none
    ) -> [GlossaryCorrection] {
        var result: [GlossaryCorrection] = []
        // The occurrences already proposed, per segment.
        var proposed = [[Range<String.Index>]](repeating: [], count: segments.count)
        // One segmentation per segment, shared by every rule checked against it. A line starts a
        // sentence only where the line before it ended one (F938): a recognizer can split a
        // sentence across lines, and "I talked to" / "Jason about the jason file." is one sentence.
        var segmented: [SegmentedText] = []
        var lineStartsASentence = true
        for segment in segments {
            segmented.append(SegmentedText(segment.text, segmenter: evidence.segmenter, startsASentence: lineStartsASentence))
            lineStartsASentence = ReplacementBoundary.startsASentence(
                at: segment.text.endIndex, in: segment.text, atTextStart: lineStartsASentence
            )
        }
        for rule in rules where !rule.heard.isEmpty && rule.heard != rule.preferred {
            let boundary = ReplacementBoundary(
                heard: rule.heard, notCoveredBy: rule.preferred, evidence: evidence, matchingCapitalised: true
            )
            for index in segments.indices {
                let text = segmented[index].text
                for range in boundary.genuineRanges(in: segmented[index]) {
                    let from = String(text[range])
                    let to = boundary.replacement(for: from)
                    let applier = ReplacementBoundary(heard: from, notCoveredBy: to, evidence: evidence)
                    guard applier.firstRange(in: segmented[index]) == range else { continue }
                    if !proposed[index].contains(where: { $0.overlaps(range) }) {
                        proposed[index].append(range)
                        result.append(GlossaryCorrection(segmentIndex: index, from: from, to: to))
                    }
                    break
                }
            }
        }
        return result
    }

    /// `text` with every rule applied, for Quick Dictation (F821), which pastes the result with no
    /// review step.
    ///
    /// Rules run in list order, each over the text the previous ones left. Within one rule, every
    /// genuine occurrence is replaced — not only the first, as one Improve proposal does per segment —
    /// because a dictation is one piece of text and the user cannot pick occurrences afterwards.
    /// "Genuine" is the same `ReplacementBoundary` the Improve sheet's matcher and applier use: not a
    /// fragment of a longer Latin word ("Jon" in "Jones"), not inside an occurrence of `preferred`
    /// (the "Jon" of an already-correct "Jonathan"), and for Chinese not part of a longer word by
    /// `evidence` (F594). Occurrences are found in the text as it was before the rule
    /// and never overlap, so a replacement is never matched again by the same rule. An empty or
    /// no-op rule changes nothing. A "Jon" that starts a sentence is an occurrence of a rule written
    /// "jon", and its replacement keeps the capital (F858); a "Jon" mid-sentence is not.
    ///
    /// Nor does a rule touch a dictated email address, URL or dotted host name
    /// (`liesInsideAnAddress`): `@ . / :` are word edges to `ReplacementBoundary`, so "jon → Jonathan"
    /// turned `jon@jon.dev` into `Jonathan@Jonathan.dev`, and dictation pastes with no review to catch
    /// it (the review of lane W). The Improve sheet keeps proposing those occurrences of the rule as
    /// written — the user sees every one there before it applies — but not of its capitalised form,
    /// which is no sentence's first word inside an address or "U.S." (F938).
    public static func applied(
        _ rules: [ReplacementRule],
        to text: String,
        evidence: CJKWordEvidence = .none
    ) -> String {
        var result = text
        for rule in rules where !rule.heard.isEmpty && rule.heard != rule.preferred {
            let boundary = ReplacementBoundary(
                heard: rule.heard, notCoveredBy: rule.preferred, evidence: evidence, matchingCapitalised: true
            )
            let ranges = boundary.genuineRanges(in: SegmentedText(result, segmenter: evidence.segmenter))
                .filter { !liesInsideAnAddress($0, in: result) }
            guard !ranges.isEmpty else { continue }
            // Built from the unmodified string, so no index is used after a mutation.
            var rebuilt = ""
            var cursor = result.startIndex
            for range in ranges {
                rebuilt += result[cursor..<range.lowerBound]
                rebuilt += boundary.replacement(for: result[range])
                cursor = range.upperBound
            }
            rebuilt += result[cursor...]
            result = rebuilt
        }
        return result
    }

    /// Whether `range` lies inside an email address, a URL or a dotted host or file name: the run of
    /// ASCII address characters around it holds an `@`, a `://`, or a `.` with a letter or digit on
    /// both sides. A sentence's own full stop ("ask Jon.") has nothing after it, and Chinese text is
    /// not ASCII, so a run never crosses into it ("版本1.2发布" keeps 会议 in the next clause free).
    static func liesInsideAnAddress(_ range: Range<String.Index>, in text: String) -> Bool {
        var start = range.lowerBound
        while start > text.startIndex, isAddressCharacter(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        var end = range.upperBound
        while end < text.endIndex, isAddressCharacter(text[end]) {
            end = text.index(after: end)
        }
        let token = Array(text[start..<end])
        if token.contains("@") || String(token).contains("://") { return true }
        return token.indices.dropFirst().dropLast().contains { index in
            token[index] == "." && isASCIIAlphanumeric(token[index - 1]) && isASCIIAlphanumeric(token[index + 1])
        }
    }

    private static func isAddressCharacter(_ character: Character) -> Bool {
        isASCIIAlphanumeric(character) || "@.:/-_~%+?=&#".contains(character)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

/// Boundary-aware matching for exact `heard → preferred` replacement rules and their F165 LLM
/// sibling (`TranscriptCorrection`). Used by both the matchers
/// (`ReplacementRuleMatcher`, and `TranscriptCorrection.glossaryCorrections` in
/// `LocalTranscriptCorrector.swift`) and the applier (`GlossaryCorrector.apply`), so a proposal and
/// its application can never disagree about which occurrence was meant (F444).
///
/// **A replacement rule also matches `heard` with its first character upper-cased where that starts
/// a sentence (F858)** — `matchingCapitalised`, which only the rule matcher and dictation pass: the
/// start of the text, or after `.` `!` `?` `。` `！` `？` or a line break, with only spaces, quotes
/// and brackets between (`startsASentence`) — but not after an abbreviation's, an initial's or a
/// number's full stop, nor at the start of a meeting line that continues the line before it, nor
/// inside an address or "U.S." (F938). The F165 model's corrections and `apply` stay exact: a
/// rule proposal names the text as it stands, so `apply` needs no case rule of its own. With the
/// variant, coverage widens to `preferred` capitalised too ("Jon smith" covers the "Jon" of a rule
/// "jon → jon smith"), the safe direction.
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
    /// `heard` with its first character upper-cased, when that differs from `heard` and the caller
    /// asked for it (F858); nil otherwise — a rule already written with a capital, one beginning with
    /// a digit or punctuation mark (`3d`, `'twas`), or Chinese. Matched only where it starts a
    /// sentence.
    private let capitalisedHeard: String?
    /// The known terms that could enclose a CJK occurrence of `heard`, worked out on first need: with
    /// hundreds of rules and a 5,000-term vocabulary, a scan per rule that never matches is waste.
    private var enclosingTermsCache: [String]?

    init(
        heard: String, notCoveredBy preferred: String, evidence: CJKWordEvidence = .none,
        matchingCapitalised: Bool = false
    ) {
        self.heard = heard
        self.preferred = preferred
        self.evidence = evidence
        let capitalised = Self.capitalisingFirstCharacter(heard)
        capitalisedHeard = matchingCapitalised && capitalised != heard ? capitalised : nil
    }

    /// What replaces the occurrence `matched` (F858): `preferred` as written, unless `matched` is the
    /// capitalised variant of `heard` (a sentence's first word) and `preferred` is written all in
    /// lower case — then `preferred` with its first character upper-cased, so the sentence keeps its
    /// capital ("jon → jonathan" turns "Jon said" into "Jonathan said"). A `preferred` with any
    /// capital of its own keeps it exactly: "ios → iOS" never becomes "IOS".
    func replacement(for matched: some StringProtocol) -> String {
        guard let capitalisedHeard, matched == capitalisedHeard,
              !preferred.contains(where: \.isUppercase) else { return preferred }
        return Self.capitalisingFirstCharacter(preferred)
    }

    /// `text` with its first character upper-cased. A digit or a punctuation mark has no capital, so
    /// a rule that begins with one has no capitalised variant.
    static func capitalisingFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Whether `index` starts a sentence (F858): the nearest character before it that is not a
    /// space, a quote or a bracket is a line break or one of `.` `!` `?` `。` `！` `？` — a `.` only
    /// where `fullStopEndsASentence` says it ends one (F938) — or there is none, and then the
    /// answer is `atTextStart`: whether the text's own start starts a sentence. Dictation's text
    /// does; a meeting's line does only where the line before it ended one (F938, the review's R2),
    /// since a recognizer can split one sentence across two lines. A comma, colon, semicolon, dash
    /// or the single character "…" ends no sentence.
    static func startsASentence(at index: String.Index, in text: String, atTextStart: Bool = true) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if character.isNewline { return true }
            if sentenceEnds.contains(character) { return character != "." || fullStopEndsASentence(at: cursor, in: text) }
            guard character.isWhitespace || quotesAndBrackets.contains(character) else { return false }
        }
        return atTextStart
    }

    /// Whether the full stop at `dot` ends a sentence (F938). It does not after a title or an
    /// abbreviation ("Mr. Bill", "vs. Jason"), a single Latin letter ("U.S. Army", "e.g. Jason",
    /// "J. Smith" — the lone word "I" excepted, "So did I. Jason left."), anything with a digit in
    /// it ("1. Jason", "Q3. Jason", "version 3. Jason"), or another full stop ("So... Jason", which
    /// now reads as the single character "…" always has). Each of these can also end a sentence ("we
    /// shipped version 3. Jason said so"), and this cannot tell which. It says no: a word left alone
    /// is what a rule did before F858, while a rewritten name is pasted by dictation with no review.
    static func fullStopEndsASentence(at dot: String.Index, in text: String) -> Bool {
        var start = dot
        while start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard previous.isLetter || previous.isNumber else { break }
            start = text.index(before: start)
        }
        let word = text[start..<dot]
        guard let first = word.first else {
            // "..." is an ellipsis; a bracket, a quote or another mark before the stop ends a sentence.
            return start == text.startIndex || text[text.index(before: start)] != "."
        }
        if word.contains(where: \.isNumber) { return false }
        if word.count == 1, LatinTokenBoundary.isConnector(first) { return word == "I" }
        return !titlesAndAbbreviations.contains(word.lowercased())
    }

    /// Words whose full stop is the abbreviation's, not a sentence's (F938). Single letters ("e.g.",
    /// "i.e.", "U.S.", "a.m.") need no entry: every single Latin letter but "I" is read as one.
    private static let titlesAndAbbreviations: Set<String> = ["mr", "mrs", "ms", "mx", "dr", "prof", "st", "jr", "sr", "vs"]

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// Skipped between a sentence's end and its first word: `He said "stop." Jon left`, `(Jon agreed.)`.
    private static let quotesAndBrackets: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "«", "»", "‹", "›",
        "(", ")", "[", "]", "{", "}", "（", "）", "【", "】", "「", "」", "『", "』", "《", "》", "〈", "〉",
    ]

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
        genuineRanges(in: segmented, stopAtFirst: true).first
    }

    /// Every genuine occurrence of `heard`, left to right and never overlapping (F821): after a
    /// genuine one the search resumes at its end, after a refused one at its next character, exactly
    /// as `firstRange` searches.
    func genuineRanges(in segmented: SegmentedText) -> [Range<String.Index>] {
        genuineRanges(in: segmented, stopAtFirst: false)
    }

    private func genuineRanges(in segmented: SegmentedText, stopAtFirst: Bool) -> [Range<String.Index>] {
        guard !heard.isEmpty else { return [] }
        let text = segmented.text
        var preferredRanges = preferred.isEmpty ? [] : Self.allRanges(of: preferred, in: text)
        if capitalisedHeard != nil, !preferred.isEmpty {
            preferredRanges += Self.allRanges(of: Self.capitalisingFirstCharacter(preferred), in: text)
        }
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let candidate = nextCandidate(in: segmented, from: searchStart) {
            let coveredByPreferred = preferredRanges.contains {
                $0.contains(candidate.lowerBound) && candidate.upperBound <= $0.upperBound
            }
            if !coveredByPreferred, isWholeWord(candidate, in: segmented) {
                found.append(candidate)
                if stopAtFirst { break }
                searchStart = candidate.upperBound
            } else {
                searchStart = text.index(after: candidate.lowerBound)
            }
        }
        return found
    }

    /// The earliest occurrence at or after `start` of `heard`, or of its capitalised variant where
    /// that starts a sentence (F858). A capitalised one mid-sentence is no candidate at all, and
    /// nor is one inside an address or a dotted abbreviation (F938): the "U" of "U.S." starts the
    /// text but is no sentence's first word, and dictation's `liesInsideAnAddress` already left it,
    /// while Improve proposed "U → You" and wrote "You.S.".
    private func nextCandidate(in segmented: SegmentedText, from start: String.Index) -> Range<String.Index>? {
        let text = segmented.text
        let exact = text.range(of: heard, range: start..<text.endIndex)
        guard let capitalisedHeard else { return exact }
        var searchStart = start
        while searchStart < text.endIndex,
              let capitalised = text.range(of: capitalisedHeard, range: searchStart..<text.endIndex),
              exact.map({ capitalised.lowerBound < $0.lowerBound }) ?? true {
            if Self.startsASentence(at: capitalised.lowerBound, in: text, atTextStart: segmented.startsASentence),
               !ReplacementRuleMatcher.liesInsideAnAddress(capitalised, in: text) {
                return capitalised
            }
            searchStart = text.index(after: capitalised.lowerBound)
        }
        return exact
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
    /// Whether the text's own start starts a sentence (F938): true for a dictation and a meeting's
    /// first line, and for a later line only where the line before it ended a sentence.
    let startsASentence: Bool
    private let segmenter: CJKWordEvidence.Segmenter?
    private var words: [Range<String.Index>]?

    init(_ text: String, segmenter: CJKWordEvidence.Segmenter?, startsASentence: Bool = true) {
        self.text = text
        self.segmenter = segmenter
        self.startsASentence = startsASentence
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
