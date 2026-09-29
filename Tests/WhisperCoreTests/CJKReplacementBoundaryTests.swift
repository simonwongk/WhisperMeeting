import Foundation
import Testing
@testable import WhisperCore

// F594 — a Chinese replacement rule had no word boundary: F444 exempted CJK from its whole-token
// check because WhisperCore cannot segment Chinese, so 会议 → 会议室 also rewrote the 会议 inside
// 整理会议纪要. `CJKWordEvidence` carries the two things that can see a Chinese word edge: a
// segmenter (the app passes NLTokenizer's) and the user's vocabulary.
//
// These tests use a small dictionary segmenter rather than NLTokenizer, so they do not depend on the
// host's segmentation dictionary. Its dictionary reproduces what NLTokenizer was measured to do on
// these words: it keeps 会议室 and 会议厅 whole and splits 会议纪要 into 会议 | 纪要.

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

/// Greedy longest-match over a fixed dictionary; any other letter is a one-character word, and
/// whitespace and punctuation are not words at all (as NLTokenizer reports them).
func dictionarySegmenter(_ dictionary: Set<String>) -> CJKWordEvidence.Segmenter {
    let longest = dictionary.map(\.count).max() ?? 1
    return { text in
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter || character.isNumber else {
                index = text.index(after: index)
                continue
            }
            var matched = text.index(after: index)
            var length = longest
            while length > 1 {
                if let end = text.index(index, offsetBy: length, limitedBy: text.endIndex),
                   dictionary.contains(String(text[index..<end])) {
                    matched = end
                    break
                }
                length -= 1
            }
            ranges.append(index..<matched)
            index = matched
        }
        return ranges
    }
}

private let measuredDictionary: Set<String> = [
    "整理", "会议", "纪要", "会议室", "会议厅", "明天", "我们", "讨论", "预算", "数据库", "数据",
]

private let rule = ReplacementRule(heard: "会议", preferred: "会议室")

@Test("A CJK rule is not proposed inside a longer vocabulary term (F594)")
func cjkRuleIsNotProposedInsideAKnownTerm() {
    // NLTokenizer splits 会议纪要 into 会议 | 纪要, so the segmenter alone cannot refuse this — the
    // user's vocabulary is what says 会议纪要 is one term.
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary), knownTerms: ["会议纪要"])
    #expect(ReplacementRuleMatcher.corrections(
        rules: [rule], segments: [seg("整理会议纪要")], evidence: evidence
    ).isEmpty)
}

@Test("A CJK rule is not proposed inside a word the segmenter keeps whole (F594)")
func cjkRuleIsNotProposedInsideASegmentedWord() {
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary))
    #expect(ReplacementRuleMatcher.corrections(
        rules: [rule], segments: [seg("我们在会议厅讨论预算")], evidence: evidence
    ).isEmpty)
}

@Test("A CJK rule still fires on the word standing alone (F594)")
func cjkRuleStillFiresOnAStandaloneWord() {
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary), knownTerms: ["会议纪要"])
    let segments = [seg("明天开会议")]
    let corrections = ReplacementRuleMatcher.corrections(rules: [rule], segments: segments, evidence: evidence)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室")])
    #expect(GlossaryCorrector.apply(corrections, to: segments, evidence: evidence)[0].text == "明天开会议室")
}

@Test("Applying a CJK rule reaches the standalone word, not the one inside a compound before it (F594)")
func applyingACJKRuleSkipsTheCompound() {
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary), knownTerms: ["会议纪要"])
    let segments = [seg("整理会议纪要，明天开会议。")]
    let corrections = ReplacementRuleMatcher.corrections(rules: [rule], segments: segments, evidence: evidence)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室")])
    // The first 会议 in the line is the one inside 会议纪要; replacing it is the corruption.
    #expect(GlossaryCorrector.apply(corrections, to: segments, evidence: evidence)[0].text == "整理会议纪要，明天开会议室。")
}

@Test("A model's CJK correction fans out only to genuine occurrences too (F594)")
func llmCorrectionsHonourTheSameBoundary() {
    // F165's corrections are fanned out to every segment containing `from` by the same function the
    // rules use, so a model that fixed one 会议 would otherwise be offered for 会议纪要 as well.
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary), knownTerms: ["会议纪要"])
    let corrections = TranscriptCorrection.glossaryCorrections(
        from: [TranscriptCorrection(from: "会议", to: "会议室")],
        segments: [seg("整理会议纪要"), seg("明天开会议")],
        evidence: evidence
    )
    #expect(corrections == [GlossaryCorrection(segmentIndex: 1, from: "会议", to: "会议室")])
}

@Test("Without evidence a CJK rule matches as it did before F594")
func noEvidenceKeepsTheOldBehaviour() {
    // The seam's default is today's behaviour; only a caller that passes evidence gets boundaries.
    #expect(ReplacementRuleMatcher.corrections(rules: [rule], segments: [seg("整理会议纪要")]) == [
        GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室"),
    ])
}

@Test("Evidence changes nothing for a Latin rule (F594 keeps F444's Latin cases)")
func evidenceLeavesLatinRulesAlone() {
    // A Latin `heard` keeps F444's whole-token rule, and a vocabulary term containing it does not
    // refuse it: known terms are how CJK, which has no visible word edge, gets one.
    let evidence = CJKWordEvidence(
        segmenter: dictionarySegmenter(measuredDictionary), knownTerms: ["Jon Snow", "Jonathan"]
    )
    let segments = [seg("Jon Snow agrees."), seg("Jones will present."), seg("Thanks Jonathan, and Jon agrees.")]
    let rules = [ReplacementRule(heard: "Jon", preferred: "Jonathan")]
    let withEvidence = ReplacementRuleMatcher.corrections(rules: rules, segments: segments, evidence: evidence)
    #expect(withEvidence == ReplacementRuleMatcher.corrections(rules: rules, segments: segments))
    #expect(withEvidence == [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 2, from: "Jon", to: "Jonathan"),
    ])
    #expect(GlossaryCorrector.apply(withEvidence, to: segments, evidence: evidence)[2].text
            == "Thanks Jonathan, and Jonathan agrees.")
}

@Test("F444's CJK preferred-covers-heard case is unchanged by evidence (F594)")
func f444CJKCaseUnchanged() {
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(measuredDictionary))
    let mixed = [seg("现在网元件已经就绪，网元还没配置。")]
    let rules = [ReplacementRule(heard: "网元", preferred: "网元件")]
    let corrections = ReplacementRuleMatcher.corrections(rules: rules, segments: mixed, evidence: evidence)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "网元", to: "网元件")])
    #expect(GlossaryCorrector.apply(corrections, to: mixed, evidence: evidence)[0].text
            == "现在网元件已经就绪，网元件还没配置。")
}

@Test("The test segmenter reproduces the segmentation it stands in for")
func dictionarySegmenterSelfCheck() {
    let text = "整理会议纪要，明天开会议。"
    let words = dictionarySegmenter(measuredDictionary)(text).map { String(text[$0]) }
    let expected: [String] = ["整理", "会议", "纪要", "明天", "开", "会议"]
    #expect(words == expected)
}
