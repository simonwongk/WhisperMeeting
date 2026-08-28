import Foundation
import Testing
@testable import WhisperCore

@Test("A plain grammar fix is accepted and cleaned")
func acceptsPlainFix() {
    let out = DictationRefinePolicy.acceptedOutput(
        "So I think we should go with the second option.",
        input: "so i think we should uh go with the the second option"
    )
    #expect(out == "So I think we should go with the second option.")
}

@Test("Wrapping quotes and code fences are stripped before checking")
func stripsWrappers() {
    #expect(DictationRefinePolicy.acceptedOutput("\"Hello there.\"", input: "hello there")
        == "Hello there.")
    #expect(DictationRefinePolicy.acceptedOutput("```\nHello there.\n```", input: "hello there")
        == "Hello there.")
    #expect(DictationRefinePolicy.acceptedOutput("“你好。”", input: "你好") == "你好。")
}

@Test("Empty output is rejected")
func rejectsEmpty() {
    #expect(DictationRefinePolicy.acceptedOutput("", input: "hello") == nil)
    #expect(DictationRefinePolicy.acceptedOutput("\"\"", input: "hello") == nil)
}

@Test("Output whose length drifts far from the input is rejected")
func rejectsLengthDrift() {
    let input = "please send the report tomorrow morning"  // 39 chars
    let bloated = String(repeating: "This model wrote an essay. ", count: 4)
    #expect(DictationRefinePolicy.acceptedOutput(bloated, input: input) == nil)
    #expect(DictationRefinePolicy.acceptedOutput("Sent.", input: input) == nil)
}

@Test("Short inputs get absolute slack so 'hi' → 'Hi.' still passes")
func shortInputSlack() {
    #expect(DictationRefinePolicy.acceptedOutput("Hi.", input: "hi") == "Hi.")
}

@Test("A script change (translation tripwire) is rejected")
func rejectsTranslation() {
    #expect(DictationRefinePolicy.acceptedOutput(
        "We meet tomorrow at nine.", input: "我们明天九点开会好不好") == nil)
    #expect(DictationRefinePolicy.acceptedOutput(
        "我们明天九点开会,好不好?", input: "我们明天九点开会好不好") != nil)
}

@Test("Internal newlines are collapsed like every dictation delivery")
func collapsesNewlines() {
    #expect(DictationRefinePolicy.acceptedOutput(
        "Hello there.\nHow are you?", input: "hello there how are you")
        == "Hello there. How are you?")
}
