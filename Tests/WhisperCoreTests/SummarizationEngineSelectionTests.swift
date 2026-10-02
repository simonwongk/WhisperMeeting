import Foundation
import Testing
@testable import WhisperCore

// F566 — with no stored preference the summarization engine defaulted to `.local` on every Mac,
// including an Intel one, where the local summarizer cannot be installed at all. Summarize then
// told the user to install a model Settings offers no button for. A missing preference is not a
// choice, so pick an engine that can run (F262's rule). A stored preference IS a choice, so keep it:
// unlike F262, which falls back from a stored engine this Mac cannot run, because switching to
// Claude would send transcripts to Anthropic. On an unsupported Mac its model is never installed,
// and AppModel.summarize's refusal then names the reason instead of an install instruction.

@Test("With no stored choice, the local engine is chosen where local summaries are supported (F566)")
func summarizationInitialSelectionDefaultsToLocalWhereSupported() {
    #expect(SummarizationEngine.initialSelection(stored: nil, isLocalSupported: true) == .local)
}

@Test("With no stored choice on a Mac without local summaries, Claude is chosen (F566)")
func summarizationInitialSelectionDefaultsToClaudeWhereLocalIsUnsupported() {
    #expect(SummarizationEngine.initialSelection(stored: nil, isLocalSupported: false) == .claude)
}

@Test("A stored choice is kept whether or not local summaries are supported (F566)")
func summarizationInitialSelectionKeepsAStoredChoice() {
    #expect(SummarizationEngine.initialSelection(stored: .local, isLocalSupported: false) == .local)
    #expect(SummarizationEngine.initialSelection(stored: .local, isLocalSupported: true) == .local)
    #expect(SummarizationEngine.initialSelection(stored: .claude, isLocalSupported: true) == .claude)
    #expect(SummarizationEngine.initialSelection(stored: .claude, isLocalSupported: false) == .claude)
}
