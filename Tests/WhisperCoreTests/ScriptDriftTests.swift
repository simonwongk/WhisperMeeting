import Foundation
import Testing
@testable import WhisperCore

// F245 — the crossing the refinement guard could not see.
//
// `DictationRefineGuardrailTests.rejectsTranslation` proves the guard refuses a Chinese dictation
// returned as English. A Chinese dictation returned in a different *script* is the same kind of
// event — the model answered in a writing system the user did not use — and the guard accepted it,
// because `TranscriptLanguage.dominant` answers "which language" and Traditional and Simplified are
// one language. Measured on 2026-09-17 by F244's harness, on neutral business content, and
// `RefinementGuardVectorTests` asserted that the shipped guard accepted it.
//
// The check is **directional** on purpose. A source-relative rule alone — "the output added
// Simplified characters the input lacked" — fires on a Simplified user's perfectly good refinement
// as soon as it introduces a word, so it is guarded by the input reading as Traditional first.

@Test("The conversion the bench observed is recognised as one (F245)")
func theObservedConversionIsDetected() {
    let source = "那個 呃 我們星期二把 Kestrel 版本出貨了 然後 嗯 倫敦辦公室星期三才收到"
    let output = "那个我们星期二把 Kestrel 版本出货了 然后伦敦办公室星期三才收到"
    #expect(ScriptDrift.isSimplifyingConversion(source: source, output: output))
    let introduced = ScriptDrift.introducedSimplified(in: output, comparedTo: source)
    #expect(introduced.contains("个"))
    #expect(introduced.contains("货"))
}

@Test("A Simplified writer's own refinement is not a conversion (F245)")
func aSimplifiedWritersRefinementIsAccepted() {
    // The false positive the direction guard exists to prevent. This output introduces 经 and 复,
    // neither of which is in the input — a source-relative rule alone would reject it, blocking a
    // Simplified user from using refinement at all.
    let source = "陈先生关掉了备份"
    let output = "陈先生关掉了备份，已经恢复。"
    #expect(!ScriptDrift.isSimplifyingConversion(source: source, output: output))
    #expect(!ScriptDrift.looksTraditional(source))
}

@Test("Traditional in, Traditional out is not a conversion (F245)")
func traditionalRoundTripIsAccepted() {
    let source = "那個 呃 我們星期二把版本出貨了"
    let output = "那個我們星期二把版本出貨了。"
    #expect(ScriptDrift.looksTraditional(source))
    #expect(!ScriptDrift.isSimplifyingConversion(source: source, output: output))
}

@Test("Text with no Chinese at all is never a conversion (F245)")
func nonChineseTextIsNeverAConversion() {
    #expect(!ScriptDrift.isSimplifyingConversion(source: "hello there", output: "Hello there."))
    #expect(!ScriptDrift.isSimplifyingConversion(source: "", output: ""))
    #expect(!ScriptDrift.looksTraditional("hello there"))
}

@Test("Shared characters are not evidence of either script (F245)")
func sharedCharactersAreNeutral() {
    // `了`, `出` and `才` map to themselves among their alternatives (`了 → 了 瞭`), so they belong
    // to both scripts. Counting them as Simplified made every Traditional sentence look converted
    // while I was building the table — the bug was in my parse, and this is what pins the fix.
    for character in "了出才后" {
        #expect(!ChineseScript.simplifiedOnly.contains(character), "\(character) is shared")
    }
    for character in "个们货伦办" {
        #expect(ChineseScript.simplifiedOnly.contains(character), "\(character) is Simplified-only")
    }
    for character in "個們貨倫辦" {
        #expect(ChineseScript.traditionalOnly.contains(character), "\(character) is Traditional-only")
    }
}

@Test("A conversion into a shared character is a known blind spot, and one is enough (F245)")
func conversionToASharedCharacterIsAKnownMiss() {
    // `後 → 后` is invisible: `后` maps to `後 后`, so it is shared and cannot be evidence. Stated
    // rather than hidden, because the mitigation is real — a genuine conversion touches many
    // characters, so missing one still leaves the rest to catch it. A single-character dictation
    // that converts only this way would pass, and that is the accepted limit.
    #expect(ScriptDrift.introducedSimplified(in: "然后", comparedTo: "然後").isEmpty)
    // The same sentence with anything else in it is caught.
    #expect(ScriptDrift.isSimplifyingConversion(source: "然後倫敦", output: "然后伦敦"))
}

@Test("The refinement guard now refuses a Traditional-to-Simplified rewrite (F245)")
func theGuardRefusesTheConversion() {
    // The finding, closed. Before this the guard returned the Simplified text and the app pasted it
    // over the user's Traditional dictation.
    let source = "那個 呃 我們星期二把 Kestrel 版本出貨了 然後 嗯 倫敦辦公室星期三才收到"
    let output = "那个我们星期二把 Kestrel 版本出货了 然后伦敦办公室星期三才收到"
    #expect(DictationRefinePolicy.acceptedOutput(output, input: source) == nil)
}

@Test("The guard still accepts the refinements it should (F245)")
func theGuardStillAcceptsGoodRefinements() {
    // The cost of a guard is what it wrongly refuses, so these matter as much as the rejection.
    #expect(
        DictationRefinePolicy.acceptedOutput(
            "那個我們星期二把版本出貨了。", input: "那個 呃 我們星期二把版本出貨了"
        ) != nil,
        "a Traditional refinement of Traditional input must pass"
    )
    #expect(
        DictationRefinePolicy.acceptedOutput(
            "陈先生关掉了备份，已经恢复。", input: "陈先生 呃 关掉了备份 已经恢复"
        ) != nil,
        "a Simplified writer must still be able to use refinement"
    )
    #expect(
        DictationRefinePolicy.acceptedOutput("Hello there.", input: "hello there") != nil,
        "English is untouched by this"
    )
}
