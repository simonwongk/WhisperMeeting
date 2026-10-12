import Foundation
import Testing
@testable import WhisperCore

// F536 made Correct Toward Vocabulary fast (terms prepared once, windows skipped by length, segments
// in parallel) and changed how it treats Chinese. Neither may change a single English suggestion.
// The oracle below is GlossaryCorrector.corrections as it stood at 8748e23, verbatim; the new pass
// must return exactly what it returns on text without Chinese — same proposals, same order.
//
// Amended since, deliberately and only where marked `amended`, for tickets that changed the
// English answer on purpose — each switchable, so a test can show the corpus exercises it:
// - F819: a proposal's phrase leaves the punctuation stuck to its outer words in the transcript,
//   except the marks that are the term's own ("by identity"; round 2 kept as many marks as the term
//   has, whatever they were — switch `f819ByIdentity` off for that rule).
// - F819 in place: but not where `apply` would then change something the untrimmed phrase did not
//   change — elsewhere in the segment, or anywhere at all when the untrimmed text is nowhere in it.
// - F820: a term equal to any window of the segment, not only to one word, is present already.
// - F820 no-op: a row `apply` would leave unchanged is not proposed.
// - F940: a term of four or more words is compared with windows up to its own number of words, and
//   is present where it equals one of them; every other term with windows of up to three, as before.

private struct Amendments {
    var f819 = true
    var f819ByIdentity = true
    var f819InPlace = true
    var f820 = true
    var f820NoOp = true
    var f940 = true
}

private enum PreF536GlossaryCorrector {
    static let similarityThreshold = 0.5
    static let maxWindow = 3

    static func corrections(
        vocabulary: [String], segments: [TranscriptSegment], amended: Amendments = Amendments()
    ) -> [GlossaryCorrection] {
        var results: [GlossaryCorrection] = []
        for (index, segment) in segments.enumerated() {
            let words = segment.text
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map(String.init)
            guard !words.isEmpty else { continue }
            let normalizedWords = words.map(normalize)

            for term in vocabulary {
                let termNormalized = normalize(term)
                guard !termNormalized.isEmpty else { continue }
                if normalizedWords.contains(termNormalized) { continue }

                var best: (similarity: Double, phrase: String)?
                var presentAsAWindow = false // amended
                let termWords = term.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count // amended
                let largest = amended.f940 ? max(maxWindow, termWords) : maxWindow // amended
                for size in 1...largest where size <= words.count { // amended (was 1...maxWindow)
                    for start in 0...(words.count - size) {
                        let windowNormalized = normalizedWords[start..<(start + size)].joined()
                        if windowNormalized == termNormalized { presentAsAWindow = true } // amended
                        guard !windowNormalized.isEmpty, windowNormalized != termNormalized else { continue }
                        let score = similarity(windowNormalized, termNormalized)
                        if score >= similarityThreshold, score > (best?.similarity ?? 0) {
                            best = (score, words[start..<(start + size)].joined(separator: " "))
                        }
                    }
                }
                if amended.f820, presentAsAWindow { continue } // amended
                if let best {
                    var phrase = amended.f819 // amended
                        ? trimmedF819(best.phrase, for: term, byIdentity: amended.f819ByIdentity) : best.phrase // amended
                    if amended.f819InPlace, phrase != best.phrase, // amended
                       !appliesInPlace(phrase, of: best.phrase, term: term, in: segment.text) { // amended
                        phrase = best.phrase // amended
                    } // amended
                    let proposal = GlossaryCorrection(segmentIndex: index, from: phrase, to: term)
                    if amended.f820NoOp, changesNothing(proposal, in: segment) { continue } // amended
                    results.append(proposal)
                }
            }
        }
        return results
    }

    /// F819, written here independently of `GlossaryCorrector.trimmingAttachedPunctuation`: drop
    /// outer characters with no letter, mark or digit in them, stopping at an ASCII word character
    /// (an underscore stays, as `LatinTokenBoundary` reads it as part of the word) — but keep the
    /// ones that are `term`'s own: the end of the window's leading marks that is also the end of the
    /// term's, and the start of its trailing marks that is also the start of the term's (".NOT"
    /// keeps its "." for ".NET"; "Ink," keeps no comma for "Inc."). With `byIdentity` off, round 2's
    /// rule: as many marks on each side as the term has, whatever they are.
    static func trimmedF819(_ phrase: String, for term: String, byIdentity: Bool) -> String {
        func keeps(_ character: Character) -> Bool {
            (character.isASCII && (character.isLetter || character.isNumber || character == "_"))
                || character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        let termCharacters = Array(term)
        let termLeading = Array(termCharacters.prefix(while: { !keeps($0) }))
        let termTrailing = Array(termCharacters.reversed().prefix(while: { !keeps($0) }).reversed())
        var characters = Array(phrase)
        var leading: [Character] = []
        while let first = characters.first, !keeps(first) { leading.append(characters.removeFirst()) }
        var trailing: [Character] = []
        while let last = characters.last, !keeps(last) { trailing.insert(characters.removeLast(), at: 0) }
        guard !characters.isEmpty else { return phrase }
        guard byIdentity else {
            // Typed separately: in one expression Swift 6.1 (the CI runner's) resolves `prefix` to
            // `Sequence`'s `PrefixSequence` and cannot add it to an `ArraySlice` (CI run 38194066710).
            let leadingByCount: [Character] = Array(leading.suffix(termLeading.count))
            let trailingByCount: [Character] = Array(trailing.prefix(termTrailing.count))
            return String(leadingByCount + characters + trailingByCount)
        }
        var keptLeading = leading
        while !keptLeading.isEmpty, !termLeading.reversed().starts(with: keptLeading.reversed()) {
            keptLeading.removeFirst()
        }
        var keptTrailing = trailing
        while !keptTrailing.isEmpty, !termTrailing.starts(with: keptTrailing) {
            keptTrailing.removeLast()
        }
        return String(keptLeading + characters + keptTrailing)
    }

    /// F820 no-op: whether applying `proposal` alone leaves `segment`'s text as it was — asked of
    /// `GlossaryCorrector.apply` itself, since what it does is the definition.
    static func changesNothing(_ proposal: GlossaryCorrection, in segment: TranscriptSegment) -> Bool {
        let alone = GlossaryCorrection(segmentIndex: 0, from: proposal.from, to: proposal.to)
        return GlossaryCorrector.apply([alone], to: [segment])[0].text == segment.text
    }

    /// F819 in place: whether `apply` would change the trimmed phrase inside the place it changes the
    /// untrimmed one. Where `apply` changes a phrase is `ReplacementBoundary`'s first genuine
    /// occurrence by definition (F444), so that is asked here rather than written a second time.
    static func appliesInPlace(_ trimmed: String, of untrimmed: String, term: String, in text: String) -> Bool {
        guard let whole = ReplacementBoundary.firstRange(of: untrimmed, notCoveredBy: term, in: text),
              let part = ReplacementBoundary.firstRange(of: trimmed, notCoveredBy: term, in: text) else { return false }
        return whole.lowerBound <= part.lowerBound && part.upperBound <= whole.upperBound
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let lcs = longestCommonSubsequence(Array(a), Array(b))
        return Double(lcs) / Double(max(a.count, b.count))
    }

    static func longestCommonSubsequence(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var dp = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var diagonal = 0
            for j in 1...b.count {
                let current = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? diagonal + 1 : max(dp[j], dp[j - 1])
                diagonal = current
            }
        }
        return dp[b.count]
    }
}

/// A seeded generator, so the synthetic transcript is the same on every machine.
private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

private let words = """
we the and to of release build team review report budget quarter customer meeting deadline schedule \
design vendor invoice friday tuesday afternoon project launch server deploy cluster pipeline metrics \
dashboard ticket said will test it on thursday number ready priya kestrel office london spring
""".split(separator: " ").map(String.init)

private let syllables = ["ka", "ze", "tro", "lin", "mar", "ves", "dor", "fen", "gal", "jor", "pel", "ros", "sta", "vin"]

/// Latin terms (one and two words, some accented or with digits), plus Chinese terms that must
/// propose nothing on English text, in collation order as the store keeps them.
private func syntheticVocabulary(_ random: inout SeededRandom) -> [String] {
    var terms: Set<String> = ["Kubernetes", "Priya Raman", "Fairhaven", "Kestrel", "Café Noir", "GPT4", "张经理", "预算"]
    while terms.count < 80 {
        var word = ""
        for _ in 0..<(2 + random.next(3)) { word += syllables[random.next(syllables.count)] }
        if random.next(4) == 0 {
            var second = ""
            for _ in 0..<(2 + random.next(2)) { second += syllables[random.next(syllables.count)] }
            word += " " + second.capitalized
        }
        terms.insert(word.capitalized)
    }
    return terms.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// English segments with a mis-heard term in about one in three, and the separators and punctuation
/// the old split treated as it did: tabs, newlines, doubled spaces, trailing commas, an accent.
private func syntheticTranscript(_ vocabulary: [String], _ random: inout SeededRandom) -> [TranscriptSegment] {
    let latin = vocabulary.filter { !ReplacementBoundary.hasCJK($0) }
    let separators = [" ", " ", " ", "  ", "\t", "\n"]
    return (0..<60).map { index in
        var parts = (0..<(4 + random.next(9))).map { _ in words[random.next(words.count)] }
        if random.next(3) == 0 {
            var characters = Array(latin[random.next(latin.count)])
            if characters.count > 3 { characters[random.next(characters.count)] = "e" }
            parts[random.next(parts.count)] = String(characters) + (random.next(3) == 0 ? "," : "")
        }
        var text = ""
        for (offset, part) in parts.enumerated() {
            text += (offset == 0 ? "" : separators[random.next(separators.count)]) + part
        }
        return TranscriptSegment(speaker: nil, start: Double(index), end: Double(index + 1), text: text + ".")
    }
}

@Test("English suggestions are exactly the pre-F536 ones on a synthetic transcript (F536)")
func englishSuggestionsMatchThePreF536Oracle() {
    var random = SeededRandom(state: 0xF536)
    let generated = syntheticVocabulary(&random)
    // Terms with outer punctuation of their own, and lines where a window's mark is the term's and
    // where it is not (the review of round 2, R6); then terms of four and five words, mishearings of
    // them, one spelled right and one across a tab (F940) — added after generating, so the seeded
    // corpus above is the one F536 pinned.
    let vocabulary = generated + ["Acme Inc.", ".NET", "(beta)", "Bank of New York", "Bank of New York Mellon"]
    let fixedLines: [String] = [
        "we signed with Acme Ink, the vendor.", "Acme Ink., the vendor, signed.", "the (NOT) runtime is old.",
        "the .NOT runtime is old.", "the betta, release ships.",
        "the Bank of New Yolk said yes.", "the Bonk of New York said yes.", "we bank with Bank of New York Melon.",
        "the Bank of New York said yes.", "the Bank\tof New York review.",
    ]
    let segments = syntheticTranscript(generated, &random) + fixedLines.enumerated().map {
        TranscriptSegment(speaker: nil, start: Double(60 + $0.offset), end: Double(61 + $0.offset), text: $0.element)
    }

    let expected = PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)
    let actual = GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)

    // The premise: the transcript is rich enough to exercise the search, and each amendment.
    #expect(expected.count >= 20, "only \(expected.count) proposals — the corpus exercises too little")
    var withoutF819 = Amendments()
    withoutF819.f819 = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withoutF819) != expected,
            "no proposal in the corpus carries punctuation, so F819's amendment is untested here")
    var byCount = Amendments()
    byCount.f819ByIdentity = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: byCount) != expected,
            "no window in the corpus has a mark that is not the term's, so F819's identity rule is untested here")
    // Judged with the no-op amendment off on both sides: a row the in-place rule leaves untrimmed
    // and unfindable is a row that changes nothing, which the no-op amendment drops either way.
    var withInPlaceOnly = Amendments()
    withInPlaceOnly.f820NoOp = false
    var withoutInPlace = withInPlaceOnly
    withoutInPlace.f819InPlace = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withoutInPlace)
        != PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withInPlaceOnly),
            "no trimmed proposal in the corpus would be applied elsewhere, so F819's in-place amendment is untested here")
    var withoutNoOp = Amendments()
    withoutNoOp.f820NoOp = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withoutNoOp) != expected,
            "no proposal in the corpus changes nothing, so F820's no-op amendment is untested here")
    var withoutF940 = Amendments()
    withoutF940.f940 = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withoutF940) != expected,
            "no term in the corpus has four or more words and a mishearing, so F940's amendment is untested here")
    let identical = actual == expected
    #expect(identical, "first difference: \(zip(actual, expected).first { $0 != $1 }.map { "\($0) vs \($1)" } ?? "counts \(actual.count) vs \(expected.count)")")
}

@Test("The review sheet's prepared term check answers exactly as touches does, span by span (F536)")
func preparedTouchingMatchesTouches() {
    // Whole words, case, a CJK substring either way round, NFC/NFD, a literal dot, an empty and a
    // padded term, and a Latin term against Chinese with no space — F245's and F534's cases.
    let terms = ["Kestrel", "CCP", "cult", "陳經理", "Node.js", "", "  Acme  ", "Cafe\u{301}", "Kubernetes", "预算"]
    let spans = [
        "kestrel", "Kestrels", "CCPA", "the culture", "陳經理說", "經理", "node.js", "nodexjs", "Acme",
        "Café", "这个Kubernetes集群", "预", "  ", "Priya", "cult", "ACME corp",
    ]
    let proposals = spans.enumerated().map { GlossaryCorrection(segmentIndex: $0.offset, from: $0.element, to: "x") }
    let perProposal = Set(proposals.indices.filter { GlossaryReviewDefaults.touchesProtectedTerm(proposals[$0], terms) })

    #expect(GlossaryReviewDefaults.touching(proposals, protectedTerms: terms) == perProposal)
    #expect(GlossaryReviewDefaults.preselected(proposals, protectedTerms: terms) == Set(proposals.indices).subtracting(perProposal))
    #expect(!perProposal.isEmpty && perProposal.count < proposals.count, "the premise: both answers occur")
}

@Test("The golden English proposals, written out (F536)")
func englishGoldenSet() {
    let vocabulary = ["Fairhaven", "Kestrel", "Kubernetes", "Priya Raman", "预算"]
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "we deployed cooper netties today"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "Priya said the Kestrol release is ready"),
        TranscriptSegment(speaker: nil, start: 2, end: 3, text: "Fairhaeven will test it on Thursday"),
        TranscriptSegment(speaker: nil, start: 3, end: 4, text: "We use Kubernetes and Kestrel daily"),
        TranscriptSegment(speaker: nil, start: 4, end: 5, text: "Priya Raman said so"),
    ]
    let expected = PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)
    // Readable pins for the three mishearings, then the whole list against the oracle.
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")))
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel")))
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 2, from: "Fairhaeven", to: "Fairhaven")))
    // F820's amendment, written out: the old code proposed deleting "said" from a correct name.
    var withoutF820 = Amendments()
    withoutF820.f820 = false
    #expect(PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, amended: withoutF820)
        .contains(GlossaryCorrection(segmentIndex: 4, from: "Priya Raman said", to: "Priya Raman")))
    #expect(!expected.contains { $0.segmentIndex == 4 })
    #expect(GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments) == expected)
}
