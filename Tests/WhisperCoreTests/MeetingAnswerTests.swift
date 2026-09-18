import Foundation
import Testing
@testable import WhisperCore

// F182 part 1 — an optional written answer in Ask Meetings, synthesized on-device from the cited
// passages. It is a fifth surface that rewrites the user's words, so it ships behind F245's kind of
// guard: an answer is shown only if every claim points at a passage that exists, it introduces no
// vocabulary term the passages do not contain, and it keeps the passages' Chinese script. Anything
// else falls back to what Ask Meetings already shows — the passages. Decided 2026-09-18 under the
// user's delegation: opt-in per question, never automatic.

private func passage(_ n: Int, _ text: String, title: String = "Planning", at: Double? = 65) -> CitedResult {
    CitedResult(meetingID: UUID(), meetingTitle: title, segmentIndex: n, timestamp: at, snippet: text, score: 1)
}

@Test("The grounding numbers each passage and carries the question (F182)")
func groundingNumbersThePassages() {
    let text = MeetingAnswerPrompt.grounding(
        question: "What discount did we agree?",
        passages: [passage(0, "We agreed fifteen percent for Kestrel."), passage(1, "Osprey stays at list price.", at: nil)]
    )
    #expect(text.contains("[1] (Planning, 1:05) We agreed fifteen percent for Kestrel."))
    #expect(text.contains("[2] (Planning) Osprey stays at list price."))
    #expect(text.hasSuffix("Question: What discount did we agree?"))
}

@Test("The system prompt demands citations and an explicit not-found (F182)")
func systemPromptDemandsCitations() {
    let prompt = MeetingAnswerPrompt.system
    #expect(prompt.contains("[1]"))
    #expect(prompt.contains(MeetingAnswerPolicy.notFoundToken))
    #expect(prompt.contains("Do not translate"))
}

@Test("An answer that cites real passages is accepted, with the passages it used (F182)")
func citedAnswerIsAccepted() {
    let passages = [passage(0, "We agreed fifteen percent for Kestrel."), passage(1, "Osprey stays at list price.")]
    let outcome = MeetingAnswerPolicy.evaluate(
        "Kestrel gets fifteen percent [1]; Osprey stays at list [2].",
        question: "discounts?", passages: passages, protectedTerms: ["Kestrel", "Osprey"]
    )
    #expect(outcome == .answer(MeetingAnswer(text: "Kestrel gets fifteen percent [1]; Osprey stays at list [2].", citedPassages: [0, 1])))
}

@Test("An answer with no citation, or one that points past the passages, is refused (F182)")
func uncitedOrMiscitedAnswersAreRefused() {
    let passages = [passage(0, "We agreed fifteen percent.")]
    #expect(MeetingAnswerPolicy.evaluate("Fifteen percent.", question: "q", passages: passages, protectedTerms: [])
            == .refused(.noCitation))
    #expect(MeetingAnswerPolicy.evaluate("Fifteen percent [3].", question: "q", passages: passages, protectedTerms: [])
            == .refused(.citesMissingPassage))
    #expect(MeetingAnswerPolicy.evaluate("   ", question: "q", passages: passages, protectedTerms: [])
            == .refused(.empty))
}

@Test("An answer that introduces a vocabulary term no passage contains is refused (F182, F245)")
func inventedProtectedTermIsRefused() {
    let passages = [passage(0, "We agreed fifteen percent for the new account.")]
    let outcome = MeetingAnswerPolicy.evaluate(
        "Kestrel gets fifteen percent [1].", question: "what discount?", passages: passages, protectedTerms: ["Kestrel"]
    )
    #expect(outcome == .refused(.introducesTerm("Kestrel")))
    // A term the user asked about is theirs, not the model's invention.
    let asked = MeetingAnswerPolicy.evaluate(
        "Nothing about Kestrel beyond fifteen percent [1].", question: "Kestrel discount?", passages: passages, protectedTerms: ["Kestrel"]
    )
    #expect(asked == .answer(MeetingAnswer(text: "Nothing about Kestrel beyond fifteen percent [1].", citedPassages: [0])))
}

@Test("A Traditional-Chinese meeting is not answered in Simplified (F182, F244)")
func scriptConversionIsRefused() {
    let passages = [passage(0, "我們決定這個價格給客戶優惠。")]
    let outcome = MeetingAnswerPolicy.evaluate("我们决定这个价格给客户优惠 [1]。", question: "價格?", passages: passages, protectedTerms: [])
    #expect(outcome == .refused(.scriptChanged))
}

@Test("The model saying the passages do not answer it is a result, not an error (F182)")
func notFoundIsAResult() {
    let outcome = MeetingAnswerPolicy.evaluate(
        " \(MeetingAnswerPolicy.notFoundToken) ", question: "q", passages: [passage(0, "x")], protectedTerms: []
    )
    #expect(outcome == .notFound)
}
