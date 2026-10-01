import Foundation
import Testing
@testable import WhisperCore

// F555 — two captions said the Claude summary path stays on this Mac. The template picker sits in
// the same row as "Summarize with Claude" and its tooltip ended "Everything stays on this Mac." for
// both engines; on a Mac that cannot run local summaries, Settings said "Choose Claude to summarize
// on this Mac." The Claude confirmation says the opposite — it is the only feature that leaves this
// Mac — and that is the claim the product spec makes, so these tests pin it from the copy's side.
//
// `summaryPrivacyCopyIsWhatContentViewShows` (WhisperMeetTests) pins that the view shows these
// values rather than literals of its own.

@Test("With Claude selected, the template tooltip does not say the summary stays on this Mac (F555)")
func summaryPrivacyCopyClaudeTemplateHelpNamesAnthropic() {
    let help = SummaryPrivacyCopy.templatePickerHelp(for: .claude)
    #expect(!help.lowercased().contains("stays on this mac"), "\(help)")
    #expect(!help.lowercased().contains("everything stays"), "\(help)")
    #expect(help.contains("Anthropic"), "\(help)")
}

@Test("With the local engine, the template tooltip keeps its on-this-Mac promise (F555)")
func summaryPrivacyCopyLocalTemplateHelpStaysLocal() {
    let help = SummaryPrivacyCopy.templatePickerHelp(for: .local)
    #expect(help.contains("on this Mac"), "\(help)")
    #expect(!help.contains("Anthropic"), "\(help)")
}

@Test("Every engine's template tooltip still says what a template does (F555)")
func summaryPrivacyCopyTemplateHelpKeepsItsPurpose() {
    for engine in SummarizationEngine.allCases {
        let help = SummaryPrivacyCopy.templatePickerHelp(for: engine)
        #expect(help.hasPrefix("Choose a template that shapes the summary's structure"), "\(engine): \(help)")
    }
}

@Test("The Intel Summaries caption says Claude sends the transcript to Anthropic, not that it summarizes on this Mac (F555)")
func summaryPrivacyCopyIntelCaptionNamesAnthropic() {
    let caption = SummaryPrivacyCopy.localSummariesUnsupportedCaption
    #expect(!caption.contains("summarize on this Mac"), "\(caption)")
    #expect(caption.contains("Apple-silicon Mac"), "\(caption)")
    #expect(caption.contains("Anthropic"), "\(caption)")
    #expect(caption.contains("transcript"), "\(caption)")
}
