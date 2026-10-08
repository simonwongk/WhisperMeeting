import Foundation
import Testing
@testable import WhisperCore

// F858 — a replacement rule matched only the exact case it was written in, so "jon → Jonathan"
// missed the "Jon" a recognizer capitalises at the start of a sentence, in Quick Dictation (F821)
// and in a meeting's Improve sheet alike. A rule now also matches its `heard` with the first letter
// capitalised, and the replacement keeps that capital. Any other case variant (JON, jON) is still
// left alone: whether a rule should reach those is a choice put to the user, not made here.

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("A lower-case rule fixes the word with a sentence-initial capital, in dictation and in the Improve sheet (F858)")
func lowerCaseRuleMatchesTheCapitalisedWord() throws {
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan")]
    #expect(ReplacementRuleMatcher.applied(rules, to: "Jon said jon was here.") == "Jonathan said Jonathan was here.")

    let segments = [seg("Jon said hi."), seg("Nobody here.")]
    let proposals = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan")])
    #expect(GlossaryCorrector.apply(proposals, to: segments)[0].text == "Jonathan said hi.")
}

@Test("The capital is carried onto a lower-case replacement, never forced onto one written with its own capitals (F858)")
func capitalIsCarriedOntoTheReplacement() {
    #expect(
        ReplacementRuleMatcher.applied([ReplacementRule(heard: "jon", preferred: "jonathan")], to: "Jon said, ask jon.")
            == "Jonathan said, ask jonathan."
    )
    // iOS and iPhone keep their own casing at the start of a sentence too.
    #expect(ReplacementRuleMatcher.applied([ReplacementRule(heard: "ios", preferred: "iOS")], to: "Ios works on ios.") == "iOS works on iOS.")
    #expect(
        ReplacementRuleMatcher.corrections(rules: [ReplacementRule(heard: "iphone", preferred: "iPhone")], segments: [seg("Iphone sales.")])
            == [GlossaryCorrection(segmentIndex: 0, from: "Iphone", to: "iPhone")]
    )
    #expect(
        ReplacementRuleMatcher.corrections(rules: [ReplacementRule(heard: "jon", preferred: "jonathan")], segments: [seg("Jon left.")])
            == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan")]
    )
}

@Test("Only the capitalised first letter is added: ALL CAPS, inner capitals and a lower-cased capital rule are unchanged (F858)")
func otherCaseVariantsAreNotMatched() {
    let lower = [ReplacementRule(heard: "jon", preferred: "Jonathan")]
    #expect(ReplacementRuleMatcher.applied(lower, to: "JON and jOn") == "JON and jOn")
    #expect(ReplacementRuleMatcher.corrections(rules: lower, segments: [seg("JON and jOn")]).isEmpty)
    // A rule written with a capital is not lower-cased to match.
    let capital = [ReplacementRule(heard: "Jon", preferred: "Jonathan")]
    #expect(ReplacementRuleMatcher.applied(capital, to: "ask jon") == "ask jon")
}

@Test("The capitalised match keeps F444's and F821's edges: a longer word, the preferred spelling, an address (F858)")
func capitalisedMatchKeepsEveryBoundary() {
    let rules = [ReplacementRule(heard: "jon", preferred: "jonathan")]
    // Jones is a longer word; Jonathan is the preferred spelling already, capitalised.
    #expect(ReplacementRuleMatcher.applied(rules, to: "Jones met Jonathan and Jon.") == "Jones met Jonathan and Jonathan.")
    #expect(ReplacementRuleMatcher.corrections(rules: rules, segments: [seg("Jonathan will present.")]).isEmpty)
    // A dictated address with the capital is still left alone (F821).
    #expect(
        ReplacementRuleMatcher.applied(rules, to: "mail Jon@Jon.dev or https://Jon.dev, then ask Jon.")
            == "mail Jon@Jon.dev or https://Jon.dev, then ask Jonathan."
    )
    // A rule whose preferred text begins with its heard text is not re-applied to the capitalised
    // preferred text either.
    let prefix = [ReplacementRule(heard: "jon", preferred: "jon smith")]
    #expect(ReplacementRuleMatcher.applied(prefix, to: "Jon smith said") == "Jon smith said")
    #expect(ReplacementRuleMatcher.corrections(rules: prefix, segments: [seg("Jon smith said")]).isEmpty)
}

@Test("A rule that only fixes case leaves the already-correct capitalised word alone (F858)")
func caseOnlyRuleIsIdempotent() {
    let rules = [ReplacementRule(heard: "kubernetes", preferred: "Kubernetes")]
    #expect(ReplacementRuleMatcher.applied(rules, to: "Kubernetes is up; kubernetes is fine.") == "Kubernetes is up; Kubernetes is fine.")
    #expect(ReplacementRuleMatcher.corrections(rules: rules, segments: [seg("Kubernetes is up.")]).isEmpty)
}

@Test("Chinese rules are unaffected by the capital variant (F858)")
func chineseRulesAreUnaffected() {
    let rules = [ReplacementRule(heard: "会议", preferred: "会议室")]
    let evidence = CJKWordEvidence(segmenter: dictionarySegmenter(["整理", "会议", "纪要", "明天", "开"]), knownTerms: ["会议纪要"])
    #expect(ReplacementRuleMatcher.applied(rules, to: "整理会议纪要，明天开会议", evidence: evidence) == "整理会议纪要，明天开会议室")
    #expect(
        ReplacementRuleMatcher.corrections(rules: rules, segments: [seg("明天开会议")], evidence: evidence)
            == [GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室")]
    )
}
