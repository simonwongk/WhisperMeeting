import Foundation
import Testing
@testable import WhisperCore

// F858 — a replacement rule matched only the exact case it was written in, so "jon → Jonathan"
// missed the "Jon" a recognizer capitalises at the start of a sentence, in Quick Dictation (F821)
// and in a meeting's Improve sheet alike. A rule now also matches its `heard` with the first
// character upper-cased where that starts a sentence, and the replacement keeps that capital.
// Mid-sentence a capital is left alone — it is what tells the person Bill from the bill, and
// dictation pastes with no review — and so is every other case variant (JON, jON). The integrator
// chose sentence starts because the ticket names them; F913 asks the user whether to go further.

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

@Test("Only the capitalised first character is added: ALL CAPS, inner capitals and a lower-cased capital rule are unchanged (F858)")
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
    // Jones is a longer word and starts the sentence; Jonathan is the preferred spelling already,
    // capitalised. The "Jon." at the end is mid-sentence: a name, left alone.
    #expect(ReplacementRuleMatcher.applied(rules, to: "Jones met Jonathan and Jon.") == "Jones met Jonathan and Jon.")
    #expect(ReplacementRuleMatcher.corrections(rules: rules, segments: [seg("Jonathan will present.")]).isEmpty)
    // A dictated address is still left alone (F821), mid-sentence and where it starts a sentence.
    #expect(
        ReplacementRuleMatcher.applied(rules, to: "mail Jon@Jon.dev or https://Jon.dev, then ask Jon.")
            == "mail Jon@Jon.dev or https://Jon.dev, then ask Jon."
    )
    #expect(
        ReplacementRuleMatcher.applied(rules, to: "Jon@Jon.dev wrote. Jon.dev is down. Jon said so.")
            == "Jon@Jon.dev wrote. Jon.dev is down. Jonathan said so."
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

@Test("A capital mid-sentence is left alone, at a sentence start it is fixed: the review's probes, in dictation and the Improve sheet (F858)")
func capitalisedWordIsMatchedOnlyAtASentenceStart() {
    // What dictation pastes, what the Improve sheet proposes, and what applying that proposal writes.
    func paths(_ heard: String, _ preferred: String, _ text: String) -> (pasted: String, proposed: [GlossaryCorrection], improved: String) {
        let rules = [ReplacementRule(heard: heard, preferred: preferred)]
        let segments = [seg(text)]
        let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
        return (ReplacementRuleMatcher.applied(rules, to: text), proposed, GlossaryCorrector.apply(proposed, to: segments)[0].text)
    }
    // The person Bill keeps his name; the bill becomes the invoice.
    let bill = paths("bill", "invoice", "Ask Bill about the bill.")
    #expect(bill.pasted == "Ask Bill about the invoice.")
    #expect(bill.proposed == [GlossaryCorrection(segmentIndex: 0, from: "bill", to: "invoice")])
    #expect(bill.improved == "Ask Bill about the invoice.")
    // Jason mid-sentence is a person; the lower-case jason is the file format.
    let jason = paths("jason", "JSON", "I asked Jason about the jason file.")
    #expect(jason.pasted == "I asked Jason about the JSON file.")
    #expect(jason.proposed == [GlossaryCorrection(segmentIndex: 0, from: "jason", to: "JSON")])
    #expect(jason.improved == "I asked Jason about the JSON file.")
    // At the start of a sentence every word has a capital, so the capital cannot tell the person
    // from the format there, and the rule fixes it: the review's own probe, unchanged by design.
    // One proposal per segment, so the lower-case "jason" waits for the next Apply.
    let jasonFirst = paths("jason", "JSON", "Jason said the jason file is broken.")
    #expect(jasonFirst.pasted == "JSON said the JSON file is broken.")
    #expect(jasonFirst.proposed == [GlossaryCorrection(segmentIndex: 0, from: "Jason", to: "JSON")])
    #expect(jasonFirst.improved == "JSON said the jason file is broken.")
    // "Plan A." ends a sentence with a capital that does not start one.
    let plan = paths("a", "the", "A plan for a team. Plan A.")
    #expect(plan.pasted == "The plan for the team. Plan A.")
    #expect(plan.proposed == [GlossaryCorrection(segmentIndex: 0, from: "A", to: "The")])
    #expect(plan.improved == "The plan for a team. Plan A.")
    // U-boat is mid-sentence. The "U" of "U.S." starts the text: dictation leaves it alone by
    // F821's address rule, and the Improve sheet proposes it, as it proposes addresses, for review.
    let you = paths("u", "you", "U.S. and U-boat and u")
    #expect(you.pasted == "U.S. and U-boat and you")
    #expect(you.proposed == [GlossaryCorrection(segmentIndex: 0, from: "U", to: "You")])
    #expect(you.improved == "You.S. and U-boat and u")
}

@Test("A sentence starts at the start of the text, or after . ! ? 。 ！ ？ or a line break, across spaces, quotes and brackets (F858)")
func sentenceStartsAreMarksLineBreaksAndTheStartOfTheText() {
    let rules = [ReplacementRule(heard: "jon", preferred: "jonathan")]
    func pasted(_ text: String) -> String { ReplacementRuleMatcher.applied(rules, to: text) }
    #expect(pasted("Done! Jon left. Really? Jon? Yes.\nJon too") == "Done! Jonathan left. Really? Jonathan? Yes.\nJonathan too")
    #expect(pasted("好的。Jon来了！Jon走了？Jon呢") == "好的。Jonathan来了！Jonathan走了？Jonathan呢")
    #expect(
        pasted("\"Jon\" said \"stop.\" Jon left. (Jon agreed.) \u{201C}Jon?\u{201D} and Jon")
            == "\"Jonathan\" said \"stop.\" Jonathan left. (Jonathan agreed.) \u{201C}Jonathan?\u{201D} and Jon"
    )
    // A comma, colon, semicolon or dash does not end a sentence.
    #expect(pasted("Note: Jon said; then Jon — and Jon, again") == "Note: Jon said; then Jon — and Jon, again")
}

@Test("A rule is proposed only where apply would put it, never as a row that rewrites a correct occurrence (F858, F444)")
func ruleProposalIsWhereApplyPutsIt() {
    // "jon → big jon" on "Big jon and jon": the first "jon" is already right — it is inside "Big
    // jon", the preferred text with a sentence's capital — so the rule means the second one. But
    // apply changes the first genuine "jon" it finds, and with no capital rule of its own that is
    // the first: "Big big jon". So the sheet proposes nothing here rather than that row; dictation,
    // which replaces the ranges it found, fixes the second.
    let rules = [ReplacementRule(heard: "jon", preferred: "big jon")]
    let segments = [seg("Big jon and jon")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed.isEmpty)
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Big jon and jon")
    #expect(ReplacementRuleMatcher.applied(rules, to: "Big jon and jon") == "Big jon and big jon")
}

@Test("Two rules that give one row propose it once, so Apply never changes an occurrence nobody reviewed (F858)")
func identicalProposalsFromTwoRulesAreOneRow() {
    // The store keeps "jon → Jonathan" and "Jon → Jonathan" as two rules, and a sentence-initial
    // "Jon" is an occurrence of both. Two identical rows, both ticked, changed the second "Jon" too.
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan"), ReplacementRule(heard: "Jon", preferred: "Jonathan")]
    let segments = [seg("Jon and Jon said"), seg("Ask Jon.")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 1, from: "Jon", to: "Jonathan"),
    ])
    #expect(GlossaryCorrector.apply(proposed, to: segments).map(\.text) == ["Jonathan and Jon said", "Ask Jonathan."])
}

@Test("Two rules aimed at one occurrence give one row, the first rule's, so Apply changes only the occurrence shown (F858)")
func oneRowPerOccurrenceAcrossRules() {
    // "bill → invoice" carries the sentence's capital and "Bill → invoice" does not, so their rows
    // for the sentence-initial "Bill" differ ("Bill → Invoice", "Bill → invoice"), and both ticked
    // changed the second "Bill", which no row showed (the Wave 5 review of round 2, R1). The first
    // rule in list order wins, as it does in dictation.
    let rules = [ReplacementRule(heard: "bill", preferred: "invoice"), ReplacementRule(heard: "Bill", preferred: "invoice")]
    let segments = [seg("Bill paid. Ask Bill.")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "Invoice")])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Invoice paid. Ask Bill.")
    // A later rule's row for a different occurrence in the same segment is still proposed.
    let other = [ReplacementRule(heard: "bill", preferred: "invoice"), ReplacementRule(heard: "acme", preferred: "Acme")]
    #expect(ReplacementRuleMatcher.corrections(rules: other, segments: [seg("Bill acme")])
        == [GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "Invoice"), GlossaryCorrection(segmentIndex: 0, from: "acme", to: "Acme")])
}

@Test("An accented Latin letter continues the word, so a rule never rewrites part of Jonás or élan (F858)")
func accentedLatinLetterContinuesTheWord() {
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan")]
    #expect(ReplacementRuleMatcher.applied(rules, to: "Jonás met jon and jonás") == "Jonás met Jonathan and jonás")
    #expect(ReplacementRuleMatcher.corrections(rules: rules, segments: [seg("Jonás said hi")]).isEmpty)
    let lan = [ReplacementRule(heard: "lan", preferred: "LAN")]
    #expect(ReplacementRuleMatcher.applied(lan, to: "the lan has élan") == "the LAN has élan")
    // Cyrillic and full-width letters are still word edges, as F592 decided.
    #expect(ReplacementRuleMatcher.applied(rules, to: "jonЙ and \u{FF4A}jon") == "JonathanЙ and \u{FF4A}Jonathan")
}
