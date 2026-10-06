import Foundation
import Testing
@testable import WhisperCore

// F536 made Correct Toward Vocabulary fast (terms prepared once, windows skipped by length, segments
// in parallel) and changed how it treats Chinese. Neither may change a single English suggestion.
// The oracle below is GlossaryCorrector.corrections as it stood at 8748e23, verbatim; the new pass
// must return exactly what it returns on text without Chinese — same proposals, same order.

private enum PreF536GlossaryCorrector {
    static let similarityThreshold = 0.5
    static let maxWindow = 3

    static func corrections(vocabulary: [String], segments: [TranscriptSegment]) -> [GlossaryCorrection] {
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
                for size in 1...maxWindow where size <= words.count {
                    for start in 0...(words.count - size) {
                        let windowNormalized = normalizedWords[start..<(start + size)].joined()
                        guard !windowNormalized.isEmpty, windowNormalized != termNormalized else { continue }
                        let score = similarity(windowNormalized, termNormalized)
                        if score >= similarityThreshold, score > (best?.similarity ?? 0) {
                            best = (score, words[start..<(start + size)].joined(separator: " "))
                        }
                    }
                }
                if let best {
                    results.append(GlossaryCorrection(segmentIndex: index, from: best.phrase, to: term))
                }
            }
        }
        return results
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
    let vocabulary = syntheticVocabulary(&random)
    let segments = syntheticTranscript(vocabulary, &random)

    let expected = PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)
    let actual = GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)

    // The premise: the transcript is rich enough to exercise the search.
    #expect(expected.count >= 20, "only \(expected.count) proposals — the corpus exercises too little")
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
    ]
    let expected = PreF536GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments)
    // Readable pins for the three mishearings, then the whole list against the oracle.
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")))
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel")))
    #expect(expected.contains(GlossaryCorrection(segmentIndex: 2, from: "Fairhaeven", to: "Fairhaven")))
    #expect(GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments) == expected)
}
