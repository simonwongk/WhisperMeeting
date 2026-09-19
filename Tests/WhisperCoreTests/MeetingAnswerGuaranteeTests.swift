import Foundation
import Testing
@testable import WhisperCore

// F328 — what the answer box actually guarantees, and F332 — what it refuses to show at all.
//
// The README promised the answer "is shown only if every sentence cites a passage on screen". The
// policy requires one `[n]` and no out-of-range `[n]`, so a two-sentence answer whose first
// sentence is entirely ungrounded was accepted and shown. This is precisely the guarantee a user is
// asked to trust the box on, so the description now matches the rule — and the rule is pinned here,
// so whichever way it changes next is a decision rather than a drift.

private func passage(_ index: Int, _ text: String) -> CitedResult {
    CitedResult(meetingID: UUID(), meetingTitle: "M", segmentIndex: index,
                timestamp: Double(index), snippet: text, score: 1)
}

@Test("Citation is checked per answer, not per sentence — and the README says so (F328)")
func answerCitationIsPerAnswerNotPerSentence() throws {
    let passages = [passage(0, "the discount was fifteen percent")]
    let outcome = MeetingAnswerPolicy.evaluate(
        "The new head of finance is Dana. The discount was fifteen percent [1].",
        question: "what was the discount", passages: passages, protectedTerms: []
    )
    guard case let .answer(answer) = outcome else {
        Issue.record("the shipped rule accepts this; if that changed, change the README with it")
        return
    }
    #expect(answer.citedPassages == [0])

    // The two rules that ARE enforced, either side of it.
    #expect(MeetingAnswerPolicy.evaluate("The discount was fifteen percent.",
                                        question: "q", passages: passages, protectedTerms: [])
            == .refused(.noCitation))
    #expect(MeetingAnswerPolicy.evaluate("The discount was fifteen percent [2].",
                                        question: "q", passages: passages, protectedTerms: [])
            == .refused(.citesMissingPassage))

    let readme = try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("README.md"), encoding: .utf8)
    #expect(!readme.contains("only if every sentence cites a passage"),
            "the product's public description must not promise more than the policy enforces")
    #expect(readme.contains("Citation is checked per answer, not per sentence"))
}

@Test("A degraded or truncated helper response is not an answer (F332)")
func degradedHelperOutputIsNotShown() {
    #expect(LocalSummarizer.answerRefusal(warning: nil, finishReason: "stop") == nil)
    #expect(LocalSummarizer.answerRefusal(warning: nil, finishReason: nil) == nil)
    #expect(LocalSummarizer.answerRefusal(warning: nil, finishReason: "length") == .answerTruncated)
    #expect(LocalSummarizer.answerRefusal(warning: "   ", finishReason: "stop") == nil,
            "an empty warning is not a warning")
    #expect(LocalSummarizer.answerRefusal(warning: "model output was not JSON", finishReason: "stop")
            == .answerDegraded("model output was not JSON"))

    // The copy must not name Claude: nothing here leaves this Mac, and saying it did would be both
    // wrong and alarming in a local-only product.
    let truncated = try? #require(SummarizerError.answerTruncated.errorDescription)
    #expect(truncated?.contains("on-device") == true)
    #expect(truncated?.contains("Claude") == false)
}
