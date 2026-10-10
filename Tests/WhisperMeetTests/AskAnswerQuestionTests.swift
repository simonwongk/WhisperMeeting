import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F850 — "Write an Answer from These Passages" sent whatever was in the Ask field to the model, with
// the passages ranked for the question last asked. Typing new words without pressing Ask and then
// pressing Write an Answer answered the new words from passages chosen for different ones. The
// answer may now be asked only for the question the passages were found for, and the button is
// disabled once the field says something else, until Ask is pressed again.

@Test("A written answer is only for the question the passages were found for (F850)")
func answerableQuestionIsTheRetrievedOne() {
    #expect(AppModel.answerableQuestion(retrievedFor: "pricing discount", typed: "pricing discount") == "pricing discount")
    // Whitespace around the words is not a different question; the one asked is what the model gets.
    #expect(AppModel.answerableQuestion(retrievedFor: "pricing discount", typed: "  pricing discount \n") == "pricing discount")
    // New words not yet asked: no answer until Ask finds passages for them.
    #expect(AppModel.answerableQuestion(retrievedFor: "pricing discount", typed: "who owns the launch") == nil)
    #expect(AppModel.answerableQuestion(retrievedFor: "pricing discount", typed: "pricing discounts") == nil)
    // Nothing asked yet.
    #expect(AppModel.answerableQuestion(retrievedFor: nil, typed: "pricing discount") == nil)
}

/// The body of the first declaration after `marker`, braces balanced, in comment- and literal-free
/// source.
private func body(following marker: String, in source: String) throws -> Substring {
    let start = try #require(source.range(of: marker), "\(marker) is gone from ContentView.swift")
    let open = try #require(source.range(of: "{", range: start.upperBound..<source.endIndex))
    var depth = 1
    var cursor = open.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    return source[open.upperBound..<cursor]
}

@Test("Ask's Write an Answer is gated on, and sends, the question the passages were found for (F850)")
func writeAnswerUsesTheRetrievedQuestion() throws {
    let structure = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8),
        blankStringLiterals: true
    )
    // The search records which question its results answer, where it sets them.
    let runSearch = try body(following: "private func runSearch()", in: structure)
    #expect(runSearch.contains("resultsQuestion = asked"))
    // Writing an answer asks the model the retrieved question, never the field's text directly.
    let writeAnswer = try body(following: "private func writeAnswer()", in: structure)
    #expect(writeAnswer.contains("AppModel.answerableQuestion(retrievedFor: resultsQuestion, typed: query)"))
    #expect(!writeAnswer.contains("let question = query"))
    // And the button is disabled while the field says something else — in its `.disabled(…)`
    // itself, which the `.help(answerQuestion == nil ? …)` beside it would satisfy on its own.
    let answerSection = try body(following: "private var answerSection", in: structure)
    let button = try #require(answerSection.range(of: "{ writeAnswer() }"), "Write an Answer's button is gone")
    let disabled = try argument(of: ".disabled(", after: button.upperBound, in: answerSection)
    #expect(disabled.contains("answerQuestion == nil"), "Write an Answer is not disabled for a changed question: \(disabled)")
}

/// The argument of the first `call` (which ends with its opening parenthesis) after `start`,
/// parentheses balanced, in comment- and literal-free source.
private func argument(of call: String, after start: Substring.Index, in source: Substring) throws -> Substring {
    let opening = try #require(source.range(of: call, range: start..<source.endIndex), "no \(call) after the button")
    var depth = 1
    var cursor = opening.upperBound
    while cursor < source.endIndex {
        if source[cursor] == "(" { depth += 1 } else if source[cursor] == ")" { depth -= 1 }
        if depth == 0 { break }
        cursor = source.index(after: cursor)
    }
    return source[opening.upperBound..<cursor]
}
