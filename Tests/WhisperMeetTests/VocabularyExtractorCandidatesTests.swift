import Foundation
import Testing
@testable import WhisperMeet

// F518 Part 1 — the name finder must keep only NLTagger's person/place/organisation tags, not its
// `.otherWord` catch-all, so ordinary words (English or Chinese) stop being saved as vocabulary.

@Test("Ordinary words are not saved as vocabulary terms, even when NLTagger tags them (F518)")
func ordinaryWordsAreNotCandidates() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "The agenda for tomorrow covers budget and hiring plans.",
        includeLineHeuristic: false
    ))
    // None of these are a person, a place, or an organisation.
    #expect(!terms.contains("The"))
    #expect(!terms.contains("agenda"))
    #expect(!terms.contains("budget"))
    #expect(!terms.contains("hiring"))
}

@Test("Ordinary Chinese words are not saved as vocabulary terms (F518)")
func ordinaryChineseWordsAreNotCandidates() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "我们明天开会讨论预算", includeLineHeuristic: false
    ))
    #expect(!terms.contains("我们"))
    #expect(!terms.contains("明天"))
}

@Test("A real person's name is still saved as a vocabulary term (F518)")
func personalNameStillMatches() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "Please loop in Priya Raman on the Kestrel release.", includeLineHeuristic: false
    ))
    #expect(terms.contains("Priya Raman"))
}

// MARK: - F518 Part 3: the document line heuristic

@Test("A short Chinese sentence ending in 。 or ！ is rejected, not saved as one term (F518)")
func chineseSentencesAreRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "本次会议讨论了预算问题。\n请大家准时参加！\n"))
    #expect(!terms.contains("本次会议讨论了预算问题。"))
    #expect(!terms.contains("请大家准时参加！"))
    // Nothing usable was salvaged from a rejected sentence either.
    #expect(!terms.contains("本次会议讨论了预算问题"))
}

@Test("An enumeration-comma-joined line splits into separate terms instead of one joined term (F518)")
func enumerationJoinedNamesSplit() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理、李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理、李总监"))
}

@Test("A full-width-comma-joined line also splits into separate terms (F518)")
func fullWidthCommaJoinedNamesSplit() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理，李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理，李总监"))
}

@Test("An ASCII-comma line is still rejected outright, unchanged from before this fix (F518)")
func asciiCommaLineStillRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "Kubernetes, Prometheus\n", includeLineHeuristic: true))
    // Neither the whole line nor a naive split survives — this ticket did not touch ASCII-comma
    // handling, only the Chinese punctuation gaps.
    #expect(!terms.contains("Kubernetes, Prometheus"))
}

@Test("A plain short line with no sentence or enumeration punctuation is still saved whole (F518)")
func plainLineStillSavedWhole() {
    let terms = Set(VocabularyExtractor.candidates(in: "Kubernetes\n"))
    #expect(terms.contains("Kubernetes"))
}

// MARK: - F518 Part 3 follow-up (review round 2): the widened rejection set dropped a term that is
// itself punctuated — "Yahoo!" — where the pre-F518 code kept it. Narrowed so a Latin
// sentence-ending mark only rejects when the line goes on to show sentence structure; a Chinese
// mark still rejects unconditionally, since no legitimate term itself ends in one.

@Test("A punctuated term on its own line survives the sentence filter (F518 follow-up)")
func punctuatedTermOnOwnLineSurvives() {
    let terms = Set(VocabularyExtractor.candidates(in: "Yahoo!\n"))
    #expect(terms.contains("Yahoo!"))
}

@Test("A Chinese sentence still rejects even when its only mark trails the line, no space, under the length cap (F518 follow-up)")
func moreChineseSentencesAreRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "这是一句话。\n请提醒我下午三点跟客户开会！\n"))
    #expect(!terms.contains("这是一句话。"))
    #expect(!terms.contains("请提醒我下午三点跟客户开会！"))
    #expect(!terms.contains("这是一句话"))
    #expect(!terms.contains("请提醒我下午三点跟客户开会"))
}

@Test("A multi-word Latin line ending in punctuation still reads as a sentence and rejects (F518 follow-up)")
func multiWordPunctuatedLineStillRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "Thank you!\n"))
    #expect(!terms.contains("Thank you!"))
}

@Test("A 、-joined list still splits after the follow-up narrowing (F518 follow-up)")
func enumerationListStillSplitsAfterFollowUp() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理、李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理、李总监"))
}
