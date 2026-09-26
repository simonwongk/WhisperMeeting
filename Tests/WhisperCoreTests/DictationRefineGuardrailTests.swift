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

// F488 — the wrapping-quote strip is for a model that wraps its whole answer in quotes. It never
// looked at the input, so a dictation that itself began and ended with quotes lost them, and
// `"Ship it tomorrow," she said, "not today."` was pasted with unbalanced quotes.
@Test("A dictation's own outer quotes survive refinement (F488)")
func keepsTheDictationsOwnWrappingQuotes() {
    let quoted = "\"Ship it tomorrow,\" she said, \"not today.\""
    #expect(DictationRefinePolicy.acceptedOutput(quoted, input: quoted) == quoted)
    #expect(DictationRefinePolicy.acceptedOutput("\"Hello.\"", input: "\"hello\"") == "\"Hello.\"")
    #expect(DictationRefinePolicy.acceptedOutput("「你好。」", input: "「你好」") == "「你好。」")
    // A model that only restyles the user's quotes has not added a wrapper either.
    #expect(DictationRefinePolicy.acceptedOutput("“Hello.”", input: "\"hello\"") == "“Hello.”")
    // But a wrapper the model added around the user's own quotes is still the model's.
    #expect(DictationRefinePolicy.acceptedOutput("\"\"Hello.\"\"", input: "\"hello\"") == "\"Hello.\"")
    #expect(DictationRefinePolicy.acceptedOutput("\"“Hello.”\"", input: "\"hello\"") == "“Hello.”")
}

@Test("A wrapper the model added around an unquoted dictation is still stripped (F488 control)")
func stillStripsAWrapperTheModelAdded() {
    #expect(DictationRefinePolicy.acceptedOutput("\"Ship it tomorrow.\"", input: "ship it tomorrow")
        == "Ship it tomorrow.")
    // Quotes inside the dictation do not count as wrapping it.
    #expect(DictationRefinePolicy.acceptedOutput("\"She said \"no.\"\"", input: "she said \"no\"")
        == "She said \"no.\"")
}

@Test("An output that translates away an embedded script entirely is rejected even when the overall dominant script is unchanged (F589)")
func rejectsDroppingAnEmbeddedScript() {
    // Real, reproduced output: refine_server.py's installed Qwen3-8B-4bit refiner, driven with the
    // app's actual prime-then-request sequence, on Scripts/bench/clips/encs1's raw ASR text. It
    // translated the two embedded Mandarin words into English instead of preserving them. Both
    // input and output are majority-English by `TranscriptLanguage.dominant`, so `rejectsTranslation`
    // above's dominant-script guard never fires on this pair — this is the gap it cannot see, and
    // it is exactly the failure F589's ticket reports: the app would have pasted this over the
    // user's words as "refined" text.
    #expect(DictationRefinePolicy.acceptedOutput(
        "Please send the meeting minutes to the whole team before Friday.",
        input: "Please send the会议纪要to the whole team before周五."
    ) == nil)

    // The symmetric direction, also a real reproduced reply: Scripts/bench/clips/cs2's embedded
    // Latin words ("schedule", "meeting") translated away from an otherwise Mandarin-dominant
    // dictation.
    #expect(DictationRefinePolicy.acceptedOutput(
        "帮我安排一个会议，明天下午。", input: "帮我 schedule 一个 meeting，明天下午。"
    ) == nil)

    // A cleanup that keeps every embedded word verbatim is still accepted — the guard must not
    // reject code-switched text outright, only a reply that erases one side of it.
    #expect(DictationRefinePolicy.acceptedOutput(
        "Please send the 会议纪要 to the whole team before 周五.",
        input: "please send the 会议纪要 to the whole team before 周五"
    ) != nil)
}
