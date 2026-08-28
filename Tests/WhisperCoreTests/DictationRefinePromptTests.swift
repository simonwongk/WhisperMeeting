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
