import Foundation
import Testing
@testable import WhisperCore

// F821 — Quick Dictation applies the user's replacement rules before pasting (the user's decision
// of 2026-10-07). There is no review step, so `ReplacementRuleMatcher.applied` replaces every
// genuine occurrence, with the same word boundaries the Improve sheet's matcher and applier use
// (F444 for Latin, F594 for Chinese). The segmenter is `dictionarySegmenter`
// (CJKReplacementBoundaryTests.swift), so nothing depends on this Mac's NLTokenizer dictionary.

private let chineseWords: Set<String> = ["整理", "会议", "纪要", "会议室", "会议厅", "明天", "我们", "讨论"]

@Test("Every genuine occurrence is replaced, and a longer word or the preferred spelling is left alone (F821)")
func appliedReplacesEveryGenuineLatinOccurrence() {
    let rules = [ReplacementRule(heard: "Jon", preferred: "Jonathan")]
    #expect(
        ReplacementRuleMatcher.applied(rules, to: "Jon met Jones and Jonathan, then Jon left.")
            == "Jonathan met Jones and Jonathan, then Jonathan left."
    )
}

@Test("A Chinese rule skips a word the segmenter keeps whole and a longer vocabulary term (F821, F594)")
func appliedKeepsChineseWordEdges() {
    let rules = [ReplacementRule(heard: "会议", preferred: "会议室")]
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(chineseWords), knownTerms: ["会议纪要"])
    #expect(
        ReplacementRuleMatcher.applied(rules, to: "整理会议纪要，我们在会议厅讨论，明天开会议，会议", evidence: evidence)
            == "整理会议纪要，我们在会议厅讨论，明天开会议室，会议室"
    )
}

@Test("Rules run in list order over the text the earlier ones left, and never re-match their own output (F821)")
func appliedRunsRulesInOrder() {
    let rules = [
        ReplacementRule(heard: "cube", preferred: "Kube"),
        ReplacementRule(heard: "Kube", preferred: "Kubernetes"),
        ReplacementRule(heard: "a", preferred: "aa"),
    ]
    #expect(ReplacementRuleMatcher.applied(rules, to: "a cube a") == "aa Kubernetes aa")
}

@Test("No rules, an empty rule or a no-op rule leaves the text exactly as it was (F821)")
func appliedWithNothingToDoIsIdentity() {
    let text = "整理会议纪要 and Jon"
    #expect(ReplacementRuleMatcher.applied([], to: text) == text)
    #expect(ReplacementRuleMatcher.applied([ReplacementRule(heard: "", preferred: "x")], to: text) == text)
    #expect(ReplacementRuleMatcher.applied([ReplacementRule(heard: "Jon", preferred: "Jon")], to: text) == text)
    #expect(ReplacementRuleMatcher.applied([ReplacementRule(heard: "Jon", preferred: "Jonathan")], to: "") == "")
}

@Test("The Improve sheet's first-occurrence search is unchanged by the all-occurrences one (F821 keeps F444/F594)")
func firstRangeIsTheFirstOfTheGenuineRanges() throws {
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(chineseWords), knownTerms: ["会议纪要"])
    let text = "整理会议纪要，我们在会议厅讨论，明天开会议，会议"
    let boundary = ReplacementBoundary(heard: "会议", notCoveredBy: "会议室", evidence: evidence)
    let all = boundary.genuineRanges(in: SegmentedText(text, segmenter: evidence.segmenter))
    #expect(all.count == 2)
    let first = try #require(ReplacementBoundary.firstRange(of: "会议", notCoveredBy: "会议室", in: text, evidence: evidence))
    #expect(first == all.first)
}
