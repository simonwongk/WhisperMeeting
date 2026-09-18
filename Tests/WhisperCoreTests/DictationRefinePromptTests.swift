import Foundation
import Testing
@testable import WhisperCore

@Test("The refine prompt forbids translation and rephrasing and demands bare text")
func promptCoreConstraints() {
    let prompt = DictationRefinePrompt.system(languageCode: nil)
    #expect(prompt.contains("never translate"))
    #expect(prompt.contains("do not rephrase"))
    #expect(prompt.contains("ONLY the corrected text"))
}

@Test("A known language adds an explicit language pin")
func promptLanguagePin() {
    #expect(DictationRefinePrompt.system(languageCode: "zh").contains("Mandarin Chinese"))
    #expect(DictationRefinePrompt.system(languageCode: "en").contains("The input is English"))
    #expect(DictationRefinePrompt.system(languageCode: "fr")
        == DictationRefinePrompt.system(languageCode: nil))
}

// MARK: - F244: name the script, so a Traditional dictation is not converted in the first place

@Test("A Traditional input names Traditional characters in the prompt, and forbids conversion (F244)")
func promptNamesTraditionalScript() {
    let prompt = DictationRefinePrompt.system(languageCode: "zh", script: .traditional)
    #expect(prompt.contains("Traditional"))
    #expect(prompt.contains("never convert"))
    #expect(prompt.hasPrefix(DictationRefinePrompt.system(languageCode: "zh")),
            "the script sentence must be appended, so the resident server's prompt cache keeps its common prefix")
}

@Test("A Simplified input names Simplified, and no script leaves the prompt as it was (F244)")
func promptNamesSimplifiedOrNothing() {
    #expect(DictationRefinePrompt.system(languageCode: "zh", script: .simplified).contains("Simplified"))
    #expect(DictationRefinePrompt.system(languageCode: "zh", script: nil)
        == DictationRefinePrompt.system(languageCode: "zh"))
    // A script only means something for Chinese; an English pin ignores it.
    #expect(DictationRefinePrompt.system(languageCode: "en", script: .traditional)
        == DictationRefinePrompt.system(languageCode: "en"))
}

@Test("The script is read from the dictation itself, never guessed (F244)")
func scriptIsDetectedFromTheText() {
    #expect(ScriptDrift.form(of: "我們星期二把版本出貨了，倫敦辦公室星期三才收到") == .traditional)
    #expect(ScriptDrift.form(of: "我们星期二把版本出货了，伦敦办公室星期三才收到") == .simplified)
    // Shared characters only: nothing to go on, so nothing is named.
    #expect(ScriptDrift.form(of: "今天很好，明天再看") == nil)
    // Mixed: the document is already inconsistent, and naming either would be a guess.
    #expect(ScriptDrift.form(of: "我們的办公室") == nil)
    #expect(ScriptDrift.form(of: "plain English") == nil)
}
