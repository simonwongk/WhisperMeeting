import Foundation
import Testing
@testable import WhisperCore

// F858 — a replacement rule matched only the exact case it was written in, so "jon → Jonathan"
// missed the "Jon" a recognizer capitalises at the start of a sentence, in Quick Dictation (F821)
// and in a meeting's Improve sheet alike. A rule now also matches its `heard` with the first
// character upper-cased where that starts a sentence, and the replacement keeps that capital.
// Mid-sentence a capital is left alone — it is what tells the person Bill from the bill, and
// dictation pastes with no review — and so is every other case variant (JON, jON). The integrator
// chose sentence starts because the ticket names them, and the user kept them on 2026-10-12 (F913);
// F938 narrows what counts as one — not after "Mr.", "U.S." or "3.", nor where a line continues.

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
    // Both occurrences are rows since F967 (one per rule per segment until then, so the lower-case
    // "jason" waited for the next Apply).
    let jasonFirst = paths("jason", "JSON", "Jason said the jason file is broken.")
    #expect(jasonFirst.pasted == "JSON said the JSON file is broken.")
    #expect(jasonFirst.proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "Jason", to: "JSON"),
        GlossaryCorrection(segmentIndex: 0, from: "jason", to: "JSON"),
    ])
    #expect(jasonFirst.improved == "JSON said the JSON file is broken.")
    // "Plan A." ends a sentence with a capital that does not start one.
    let plan = paths("a", "the", "A plan for a team. Plan A.")
    #expect(plan.pasted == "The plan for the team. Plan A.")
    #expect(plan.proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "A", to: "The"),
        GlossaryCorrection(segmentIndex: 0, from: "a", to: "the"),
    ])
    #expect(plan.improved == "The plan for the team. Plan A.")
    // U-boat is mid-sentence. The "U" of "U.S." starts the text, but it is a letter of an
    // abbreviation, not a sentence's first word: dictation leaves it alone, and since F938 so does
    // the Improve sheet, which proposed "U → You" (ticked, as rule rows are) and wrote "You.S.".
    let you = paths("u", "you", "U.S. and U-boat and u")
    #expect(you.pasted == "U.S. and U-boat and you")
    #expect(you.proposed == [GlossaryCorrection(segmentIndex: 0, from: "u", to: "you")])
    #expect(you.improved == "U.S. and U-boat and you")
}

@Test("An abbreviation's, an initial's, a number's or an ellipsis's full stop starts no sentence; a real one after them still does (F938)")
func abbreviationsAndNumbersStartNoSentence() {
    func paths(_ heard: String, _ preferred: String, _ text: String) -> (pasted: String, proposed: [GlossaryCorrection], improved: String) {
        let rules = [ReplacementRule(heard: heard, preferred: preferred)]
        let segments = [seg(text)]
        let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
        return (ReplacementRuleMatcher.applied(rules, to: text), proposed, GlossaryCorrector.apply(proposed, to: segments)[0].text)
    }
    // The ticket's example: Mr. Bill keeps his name, and the bill becomes the invoice.
    let bill = paths("bill", "invoice", "Ask Mr. Bill about the bill.")
    #expect(bill.pasted == "Ask Mr. Bill about the invoice.")
    #expect(bill.proposed == [GlossaryCorrection(segmentIndex: 0, from: "bill", to: "invoice")])
    #expect(bill.improved == "Ask Mr. Bill about the invoice.")
    // A title, an abbreviation, an initial, a list number, a version, a quarter and an ASCII
    // ellipsis (which now reads as the single character "…" always has): none ends a sentence here.
    let notSentenceStarts = [
        "Ask Mr. Jason.", "Ask Mrs. Jason.", "Ask Ms. Jason.", "Ask Dr. Jason.", "Ask Prof. Jason.",
        "On St. Jason day.", "Bears vs. Jason today.", "Use a format, e.g. Jason here.", "A format, i.e. Jason here.",
        "The U.S. Jason team.", "Ask J. Jason now.", "1. Jason said so.", "Q3. Jason said so.",
        "We shipped version 3. Jason said so.", "So... Jason, what do you think?", "So\u{2026} Jason, what do you think?",
    ]
    for text in notSentenceStarts {
        let jason = paths("jason", "JSON", text)
        #expect(jason.pasted == text)
        #expect(jason.proposed.isEmpty, "\(text)")
    }
    // A real sentence start after them is still one: the full stop after "this one", "Smith" or "I".
    let afterEG = paths("jason", "JSON", "Use a format, e.g. this one. Jason works.")
    #expect(afterEG.pasted == "Use a format, e.g. this one. JSON works.")
    #expect(afterEG.proposed == [GlossaryCorrection(segmentIndex: 0, from: "Jason", to: "JSON")])
    #expect(afterEG.improved == "Use a format, e.g. this one. JSON works.")
    #expect(paths("jason", "JSON", "Ask Mr. Smith. Jason works.").pasted == "Ask Mr. Smith. JSON works.")
    #expect(paths("jason", "JSON", "So did I. Jason left.").pasted == "So did I. JSON left.")
    #expect(paths("jason", "JSON", "Mr. Jason. Jason left.").pasted == "Mr. Jason. JSON left.")
    // A full stop after a closing bracket or quote is still a sentence's.
    #expect(paths("jason", "JSON", "It works (mostly). Jason said so.").pasted == "It works (mostly). JSON said so.")
}

@Test("A segment continues its sentence unless the segment before it ended one (F938)")
func aSegmentStartsASentenceOnlyAfterOneEnded() {
    let rules = [ReplacementRule(heard: "jason", preferred: "JSON")]
    func proposed(_ lines: [String]) -> [GlossaryCorrection] {
        ReplacementRuleMatcher.corrections(rules: rules, segments: lines.map(seg))
    }
    // The review's case: a recognizer split one sentence across two lines, and the name that
    // begins the second line is mid-sentence. The lower-case "jason" is the one meant.
    let continued = ["I talked to", "Jason about the jason file."]
    #expect(proposed(continued) == [GlossaryCorrection(segmentIndex: 1, from: "jason", to: "JSON")])
    #expect(GlossaryCorrector.apply(proposed(continued), to: continued.map(seg)).map(\.text)
        == ["I talked to", "Jason about the JSON file."])
    // After a line that ended its sentence, the next line's first word starts one; the first line
    // always does, and an empty line between says nothing either way.
    #expect(proposed(["Done.", "Jason said so."]) == [GlossaryCorrection(segmentIndex: 1, from: "Jason", to: "JSON")])
    #expect(proposed(["Jason said so."]) == [GlossaryCorrection(segmentIndex: 0, from: "Jason", to: "JSON")])
    #expect(proposed(["Done.", "  ", "Jason said so."]) == [GlossaryCorrection(segmentIndex: 2, from: "Jason", to: "JSON")])
    #expect(proposed(["I talked to", "", "Jason today."]).isEmpty)
    // A line ending in an abbreviation continues into the next.
    #expect(proposed(["I met Mr.", "Jason today."]).isEmpty)
}

@Test("A sentence starts at the start of the text, or after . ! ? 。 ！ ？ or a line break, across spaces, quotes and brackets (F858)")
func sentenceStartsAreMarksLineBreaksAndTheStartOfTheText() {
    let rules = [ReplacementRule(heard: "jon", preferred: "jonathan")]
    func pasted(_ text: String) -> String { ReplacementRuleMatcher.applied(rules, to: text) }
    #expect(pasted("Done! Jon left. Really? Jon? Yes.\nJon too") == "Done! Jonathan left. Really? Jonathan? Yes.\nJonathan too")
    // A line break ends a sentence with no mark before it.
    #expect(pasted("ok\nJon left") == "ok\nJonathan left")
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
    // apply, with no capital rule of its own, finds the first genuine "jon" first: a row naming only
    // its text wrote "Big big jon", so until F950 the sheet proposed nothing here. The row now
    // carries the second one's place, apply writes there, and the sheet agrees with dictation.
    let rules = [ReplacementRule(heard: "jon", preferred: "big jon")]
    let segments = [seg("Big jon and jon")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [GlossaryCorrection(segmentIndex: 0, from: "jon", to: "big jon", characterOffset: 12)])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Big jon and big jon")
    #expect(ReplacementRuleMatcher.applied(rules, to: "Big jon and jon") == "Big jon and big jon")
}

@Test("Improve proposes a sentence-start capital after the same word mid-sentence, at its own place, as dictation fixes it (F950)")
func sentenceStartAfterTheSameWordMidSentenceIsProposed() throws {
    let rules = [ReplacementRule(heard: "jon", preferred: "jonathan")]
    // Apply every row, then propose again, until nothing more is proposed — what a user repeating
    // Improve ▸ Apply Replacement Rules gets. Each round must change the text, so this ends.
    func improved(_ text: String) throws -> String {
        var segments = [seg(text)]
        while true {
            let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
            if proposed.isEmpty { return segments[0].text }
            let next = GlossaryCorrector.apply(proposed, to: segments)
            try #require(next != segments, "a round of rows changed nothing: \(proposed)")
            segments = next
        }
    }
    // The review's three texts: the mid-sentence name stays, the sentence's first word is fixed.
    let zoe = "Zoë and Jon. Jon left."
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: [seg(zoe)])
    #expect(proposed == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13)])
    let row = GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13)
    #expect(GlossaryCorrector.context(of: row, in: zoe) == ProposalContext(before: "Zoë and Jon. ", match: "Jon", after: " left."))
    for text in [zoe, "I met Jon today. Jon said hi.", "Ask Jon. Then jon. Jon left."] {
        #expect(try improved(text) == ReplacementRuleMatcher.applied(rules, to: text))
    }
    #expect(try improved(zoe) == "Zoë and Jon. Jonathan left.")
    #expect(try improved("Ask Jon. Then jon. Jon left.") == "Ask Jon. Then jonathan. Jonathan left.")
}

@Test("A row whose place no longer reads its text changes nothing, rather than the first occurrence (F950)")
func aRowWhosePlaceHasChangedIsNotApplied() {
    let row = GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13)
    // The line was changed between proposing and applying: its place now holds another word.
    #expect(GlossaryCorrector.apply([row], to: [seg("Zoë and Jon. Bob left.")])[0].text == "Zoë and Jon. Bob left.")
    #expect(GlossaryCorrector.context(of: row, in: "Zoë and Jon. Bob left.") == nil)
    // Its place reads "Jon" but inside a longer word: not a genuine occurrence, so not changed either.
    #expect(GlossaryCorrector.apply([row], to: [seg("Zoë and Jon. Jones left.")])[0].text == "Zoë and Jon. Jones left.")
    // Nor is a later genuine "Jon" taken instead of the place: only an occurrence that starts there
    // (the Wave 6 review of lane T, mutant M-A).
    #expect(GlossaryCorrector.apply([row], to: [seg("Zoë and Jon. Bob and Jon left.")])[0].text == "Zoë and Jon. Bob and Jon left.")
    // Unchanged, it applies where it was proposed.
    #expect(GlossaryCorrector.apply([row], to: [seg("Zoë and Jon. Jon left.")])[0].text == "Zoë and Jon. Jonathan left.")
}

@Test("Two rules that give one row propose it once, so Apply never changes an occurrence nobody reviewed (F858)")
func identicalProposalsFromTwoRulesAreOneRow() {
    // The store keeps "jon → Jonathan" and "Jon → Jonathan" as two rules, and a sentence-initial
    // "Jon" is an occurrence of both. Two identical rows, both ticked, changed the second "Jon" too.
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan"), ReplacementRule(heard: "Jon", preferred: "Jonathan")]
    let segments = [seg("Jon and Jon said"), seg("Ask Jon.")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    // The sentence-initial "Jon" is one row (the first rule's); the mid-sentence "Jon" is no
    // occurrence of the lower-case rule, and the second rule's own row for it carries its place —
    // every occurrence is a row since F967, where until then a segment got one row per rule.
    #expect(proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 8),
        GlossaryCorrection(segmentIndex: 1, from: "Jon", to: "Jonathan"),
    ])
    #expect(GlossaryCorrector.apply(proposed, to: segments).map(\.text) == ["Jonathan and Jonathan said", "Ask Jonathan."])
    #expect(GlossaryCorrector.apply([proposed[0], proposed[2]], to: segments).map(\.text) == ["Jonathan and Jon said", "Ask Jonathan."])
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
    // The second rule, written with a capital, also reaches the mid-sentence "Bill", which is a row
    // of its own since F967 (until then a segment got one row per rule, so it waited); the two rows
    // never aim at one occurrence.
    #expect(proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "Invoice"),
        GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "invoice", characterOffset: 15),
    ])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Invoice paid. Ask invoice.")
    #expect(GlossaryCorrector.apply([proposed[0]], to: segments)[0].text == "Invoice paid. Ask Bill.")
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

@Test("A letter written with a separate combining accent continues the word too, in dictation and Improve (F951)")
func decomposedAccentContinuesTheWord() {
    // "á" as "a" + U+0301 is one Character of two scalars, which F858's check read as a word edge:
    // dictation pasted "Jonathanás met Jonathan." and Improve proposed the "Jon" of Jonás.
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan")]
    let decomposed = "Jona\u{301}s met jon."
    #expect(decomposed.unicodeScalars.count == decomposed.count + 1, "the premise: the accent is a scalar of its own")
    #expect(ReplacementRuleMatcher.applied(rules, to: decomposed) == "Jona\u{301}s met Jonathan.")
    let segments = [seg(decomposed)]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan")])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Jona\u{301}s met Jonathan.")
    // Before the word as well as after it: "élan" with its accent decomposed.
    let lan = [ReplacementRule(heard: "lan", preferred: "LAN")]
    #expect(ReplacementRuleMatcher.applied(lan, to: "the lan has e\u{301}lan") == "the LAN has e\u{301}lan")
    let lanSegments = [seg("e\u{301}lan and the lan")]
    let lanProposed = ReplacementRuleMatcher.corrections(rules: lan, segments: lanSegments)
    #expect(lanProposed == [GlossaryCorrection(segmentIndex: 0, from: "lan", to: "LAN")])
    #expect(GlossaryCorrector.apply(lanProposed, to: lanSegments)[0].text == "e\u{301}lan and the LAN")
    // A mark after a character that is no Latin letter keeps it an edge: a space with an accent on
    // it is still a space, and a Cyrillic letter with one is still another script.
    #expect(ReplacementRuleMatcher.applied(rules, to: "Й\u{301}jon and jon") == "Й\u{301}Jonathan and Jonathan")
}

@Test("Every occurrence of a rule in a segment gets its own row, each at its place, so one Apply does what dictation does (F967)")
func everyOccurrenceInASegmentGetsARow() {
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan")]
    // One row per rule per segment was F444's design, so "Jon met jon" needed a second Apply for
    // the second "jon". Since F950 a row can name its place, so each occurrence gets a row.
    let met = [seg("Jon met jon")]
    let metRows = ReplacementRuleMatcher.corrections(rules: rules, segments: met)
    #expect(metRows == [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan"),
    ])
    #expect(GlossaryCorrector.apply(metRows, to: met)[0].text == "Jonathan met Jonathan")
    // The name "Jon" mid-sentence is no occurrence of a lower-case rule (F858); the "jon" and the
    // sentence's first "Jon" after it are two rows, the second carrying its place (F950), and
    // ticking either one applies just that one.
    let three = [seg("Ask Jon. Then jon. Jon left.")]
    let rows = ReplacementRuleMatcher.corrections(rules: rules, segments: three)
    let expectedRows = [
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 19),
    ]
    #expect(rows == expectedRows)
    #expect(GlossaryCorrector.apply(rows, to: three)[0].text == ReplacementRuleMatcher.applied(rules, to: three[0].text))
    #expect(GlossaryCorrector.apply([expectedRows[1]], to: three)[0].text == "Ask Jon. Then jon. Jonathan left.")
    #expect(GlossaryCorrector.apply([expectedRows[0]], to: three)[0].text == "Ask Jon. Then Jonathan. Jon left.")
    // An occurrence an earlier rule already proposed is still one row, the first rule's; the later
    // rule's other occurrences in the segment are rows of their own.
    let two = [ReplacementRule(heard: "bill", preferred: "invoice"), ReplacementRule(heard: "Bill", preferred: "invoice")]
    let paid = [seg("Bill paid. Ask Bill.")]
    let paidRows = ReplacementRuleMatcher.corrections(rules: two, segments: paid)
    #expect(paidRows == [
        GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "Invoice"),
        GlossaryCorrection(segmentIndex: 0, from: "Bill", to: "invoice", characterOffset: 15),
    ])
    #expect(GlossaryCorrector.apply(paidRows, to: paid)[0].text == ReplacementRuleMatcher.applied(two, to: paid[0].text))
    #expect(GlossaryCorrector.apply(paidRows, to: paid)[0].text == "Invoice paid. Ask invoice.")
}
