import Foundation
import Testing
@testable import WhisperCore

// F245 — a term the user has told the app about must survive a model pass unchanged. The list is
// the user's own Business Vocabulary: user-owned, local, and already the thing the correction
// features steer toward — so nothing has to guess which words matter, and no political list ships
// in a public repository.
//
// The matching rule is the F244 scorer's (`score.contains_term`): CJK as a substring because it
// has no word boundaries, Latin as whole words, case-insensitively — an exploratory run of the
// bench flagged "cult" inside "culture", which is the failure whole-word matching prevents.

@Test("Latin terms match whole words only, case-insensitively (F245)")
func latinTermsMatchWholeWords() {
    #expect(ProtectedTerms.contains("We shipped the Kestrel release.", term: "kestrel"))
    #expect(!ProtectedTerms.contains("A cultured audience.", term: "cult"))
    #expect(ProtectedTerms.contains("quit the CCP today", term: "CCP"))
    #expect(!ProtectedTerms.contains("the CCPA statute", term: "CCP"))
}

@Test("CJK terms match as substrings, and composition does not matter (F245)")
func cjkTermsMatchAsSubstrings() {
    #expect(ProtectedTerms.contains("中共自1999年迫害法輪功學員", term: "法輪功"))
    #expect(!ProtectedTerms.contains("中共自1999年迫害法輪大法學員", term: "法輪功"))
    // NFC vs NFD of the same text is the same text.
    #expect(ProtectedTerms.contains("Café Kestrel", term: "Cafe\u{0301} Kestrel"))
}

@Test("The terms an output lost are exactly the input's terms it no longer contains (F245)")
func missingTermsAreInputTermsAbsentFromOutput() {
    let terms = ["法輪功", "中共", "Kestrel", "Fairhaven"]
    let input = "那個 中共 迫害 法輪功 學員 然後 Kestrel 版本"
    let output = "中國迫害法輪功學員，然後 Kestrel 版本。"
    #expect(ProtectedTerms.missing(from: output, comparedTo: input, terms: terms) == ["中共"])
    // A term the input never had is not "missing" — the guard measures the model, not the corpus.
    #expect(ProtectedTerms.missing(from: "hi", comparedTo: "hi", terms: terms).isEmpty)
}

// F437 prepares each text once per call instead of once per term. These pin the rule itself on
// the inputs where preparing could change an answer — the text's own composition, escaping, case
// beyond ASCII — and hold for the per-term code this replaced as well as for the new one.
@Test("Normalising and bridging a text once per call keeps every answer the per-term rule gave (F437)")
func preparedTextKeepsTheRule() {
    // The TEXT's composition does not matter either, not only the term's.
    #expect(ProtectedTerms.contains("Cafe\u{0301} Kestrel opened", term: "Café"))
    #expect(ProtectedTerms.missing(from: "Cafe\u{0301} Kestrel", comparedTo: "Café Kestrel", terms: ["Café"]).isEmpty)
    // A term is matched literally: its dot is not a regex wildcard.
    #expect(ProtectedTerms.contains("try Node.js today", term: "Node.js"))
    #expect(!ProtectedTerms.contains("try NodeXjs today", term: "Node.js"))
    // Case folding reaches beyond ASCII.
    #expect(ProtectedTerms.contains("L'ÉCOLE est fermée", term: "école"))
    #expect(!ProtectedTerms.contains("anything", term: ""))

    let input = "Kestrel met Fairhaven at the École; 法輪功 and Node.js came up."
    let output = "Kestrel met at the ECOLE; Node.js came up."
    let terms = ["kestrel", "Fairhaven", "École", "法輪功", "Node.js", "Tiananmen", ""]
    #expect(ProtectedTerms.missing(from: output, comparedTo: input, terms: terms) == ["Fairhaven", "École", "法輪功"])
    // The batch answer is the per-term answer, term by term.
    #expect(ProtectedTerms.missing(from: output, comparedTo: input, terms: terms)
        == terms.filter { ProtectedTerms.contains(input, term: $0) && !ProtectedTerms.contains(output, term: $0) })
}

@Test("A span touches a term when the term lies inside it or it lies inside the term (F245)")
func spanTouchesTerm() {
    let terms = ["法輪功", "Chen Yi-chun", "台灣"]
    #expect(ProtectedTerms.touches("法輪功學員", terms: terms))
    #expect(ProtectedTerms.touches("Chen", terms: terms))          // part of a protected name
    #expect(ProtectedTerms.touches("台灣", terms: terms))
    #expect(!ProtectedTerms.touches("Kestrol", terms: terms))
    #expect(!ProtectedTerms.touches("台北", terms: terms))
}

// MARK: - the refinement guard

@Test("A refinement that drops a vocabulary term is refused, and the raw text ships (F245)")
func refinementLosingATermIsRefused() {
    let input = "um we agreed the Kestrel release ships tuesday you know"
    let good = "We agreed the Kestrel release ships Tuesday."
    let renamed = "We agreed the Kestral release ships Tuesday."
    #expect(DictationRefinePolicy.acceptedOutput(good, input: input, protectedTerms: ["Kestrel"]) == good)
    #expect(DictationRefinePolicy.acceptedOutput(renamed, input: input, protectedTerms: ["Kestrel"]) == nil)
    // Without a list, behaviour is exactly what it was.
    #expect(DictationRefinePolicy.acceptedOutput(renamed, input: input) == renamed)
}

@Test("The guard measures the input's terms only, so a vocabulary the dictation never used costs nothing (F245)")
func refinementGuardIgnoresUnusedTerms() {
    let input = "um so the office picked it up wednesday"
    let output = "The office picked it up Wednesday."
    #expect(DictationRefinePolicy.acceptedOutput(output, input: input, protectedTerms: ["Kestrel", "法輪功"]) == output)
}

// MARK: - the review sheet's defaults

@Test("A proposal that rewrites a vocabulary term is not pre-selected; the rest still are (F245)")
func reviewSheetDoesNotPreselectTermRewrites() {
    let proposals = [
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 1, from: "陳經理", to: "陳怡君"),
        GlossaryCorrection(segmentIndex: 2, from: "Fairhaeven", to: "Fairhaven"),
        GlossaryCorrection(segmentIndex: 3, from: "Priya", to: "Pria"),
    ]
    let terms = ["Kestrel", "Fairhaven", "陳經理", "Priya Raman"]
    #expect(GlossaryReviewDefaults.preselected(proposals, protectedTerms: terms) == [0, 2])
    #expect(GlossaryReviewDefaults.touchesProtectedTerm(proposals[1], terms))
    #expect(GlossaryReviewDefaults.touchesProtectedTerm(proposals[3], terms))
    // No vocabulary: today's behaviour, everything ticked.
    #expect(GlossaryReviewDefaults.preselected(proposals, protectedTerms: []) == [0, 1, 2, 3])
}

// MARK: - the summary coverage note

@Test("The coverage note names the transcript's vocabulary terms the summary never mentions (F245)")
func summaryCoverageNamesTheUnmentioned() {
    let summary = MeetingSummary(
        summary: "Falun Gong practitioners have been persecuted in China since 1999.",
        keyPoints: ["Organ harvesting allegations were discussed."],
        actionItems: ["Send the Kestrel report"]
    )
    let transcript = "The CCP has persecuted Falun Gong since 1999. Forced organ harvesting. Also the Kestrel report and the Fairhaven office."
    let terms = ["CCP", "Falun Gong", "organ harvesting", "Kestrel", "Fairhaven", "Tiananmen"]
    #expect(SummaryCoverage.unmentioned(in: summary, transcript: transcript, terms: terms) == ["CCP", "Fairhaven"])
}
