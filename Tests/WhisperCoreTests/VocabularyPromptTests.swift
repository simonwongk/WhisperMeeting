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

@Test("terms() trims, drops empties, and caps at 100")
func vocabularyPromptTermsList() {
    #expect(VocabularyPrompt.terms(["  Acme ", "", "Q3"]) == ["Acme", "Q3"])
    #expect(VocabularyPrompt.terms((1...150).map { "t\($0)" }).count == 100)
}

@Test("generationPrompt is a non-empty, definition-free instruction the user can paste to an AI")
func vocabularyGenerationPrompt() {
    let prompt = VocabularyPrompt.generationPrompt
    #expect(!prompt.isEmpty)
    // Must instruct one-term-per-line output so the result pastes cleanly into the Add box.
    #expect(prompt.contains("one per line"))
    // Must preserve original script (English + Chinese), never translate.
    #expect(prompt.contains("Do NOT romanize or translate"))
    // Must respect the vocabulary budget (<= 100 terms kept).
    #expect(prompt.contains("at most 80 terms"))
}

@Test("isPromptEcho flags a multi-term regurgitation, never a single dictated term")
func vocabularyPromptEchoDetection() {
    let vocab = ["Acme", "Kubernetes", "客户成功"]
    // A real single-term dictation must NOT be treated as an echo.
    #expect(!VocabularyPrompt.isPromptEcho("Kubernetes", terms: vocab))
    #expect(!VocabularyPrompt.isPromptEcho("客户成功", terms: vocab))
    // Two+ consecutive terms echoed back (punctuation/case/space-insensitive) IS an echo.
    #expect(VocabularyPrompt.isPromptEcho("Acme, Kubernetes", terms: vocab))
    #expect(VocabularyPrompt.isPromptEcho("kubernetes 客户成功", terms: vocab))
    // Real speech that isn't the vocab list is not an echo.
    #expect(!VocabularyPrompt.isPromptEcho("send me the report", terms: vocab))
    // Fewer than two usable terms can't be distinguished from real dictation → never an echo.
    #expect(!VocabularyPrompt.isPromptEcho("Acme", terms: ["Acme"]))
    #expect(!VocabularyPrompt.isPromptEcho("anything", terms: []))
}
