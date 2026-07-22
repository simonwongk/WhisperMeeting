import Testing
@testable import WhisperCore

@Test("Empty input builds an empty prompt")
func vocabularyPromptEmptyInput() {
    #expect(VocabularyPrompt.build([]) == "")
}

@Test("Terms are joined with a comma and space")
func vocabularyPromptJoinsWithCommaSpace() {
    #expect(VocabularyPrompt.build(["Acme", "客户成功", "Q3"]) == "Acme, 客户成功, Q3")
}

@Test("Empty and whitespace-only terms are trimmed and dropped")
func vocabularyPromptDropsEmptiesAndWhitespace() {
    #expect(VocabularyPrompt.build(["  Acme  ", "", "   ", "Q3"]) == "Acme, Q3")
}

@Test("The prompt caps at 100 terms")
func vocabularyPromptCapsAtHundredTerms() {
    let terms = (1...150).map { "term\($0)" }
    let prompt = VocabularyPrompt.build(terms)
    let joinedTerms = prompt.components(separatedBy: ", ")
    #expect(joinedTerms.count == 100)
    #expect(joinedTerms.first == "term1")
    #expect(joinedTerms.last == "term100")
}

@Test("The prompt truncates at 1000 characters even under the term cap")
func vocabularyPromptTruncatesAtThousandCharacters() {
    let terms = (1...100).map { _ in String(repeating: "x", count: 20) }
    let prompt = VocabularyPrompt.build(terms)
    #expect(prompt.count == 1_000)
}
