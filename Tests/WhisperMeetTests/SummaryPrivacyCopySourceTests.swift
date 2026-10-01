import Foundation
import Testing

// F555 — the template picker's tooltip and the Intel Summaries caption said the Claude path stays on
// this Mac. Their wording is pinned in `WhisperCoreTests/SummaryPrivacyCopyTests.swift`; this file
// pins that `ContentView` shows those values, because the target has no view-render harness (F174)
// and a literal left in the view body is copy no test can read. Comments are stripped first (F285),
// so a comment quoting the old wording cannot satisfy or fail a check.
//
// Each check is reduced to a Bool before `#expect`, so a failure names the check rather than
// printing the whole of ContentView.

@Test("ContentView's summary template tooltip and Intel caption come from SummaryPrivacyCopy (F555)")
func summaryPrivacyCopyIsWhatContentViewShows() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let keepsOldTooltip = source.contains("Everything stays on this Mac")
    let keepsOldIntelCaption = source.contains("Choose Claude to summarize on this Mac")
    #expect(!keepsOldTooltip, "ContentView still says \"Everything stays on this Mac\"")
    #expect(!keepsOldIntelCaption, "ContentView still says \"Choose Claude to summarize on this Mac\"")

    // The tooltip belongs to the template picker; read the picker's own modifiers, not the file.
    let picker = try #require(source.range(of: "Picker(\"Meeting template\""))
    let pickerModifiers = String(source[picker.lowerBound...].prefix(600))
    let pickerUsesEngineAwareHelp = pickerModifiers.contains(
        ".help(SummaryPrivacyCopy.templatePickerHelp(for: model.summarizationEngine))"
    )
    #expect(pickerUsesEngineAwareHelp, "The template picker's .help is not the engine-aware copy:\n\(pickerModifiers)")
    let showsIntelCaption = source.contains("Text(SummaryPrivacyCopy.localSummariesUnsupportedCaption)")
    #expect(showsIntelCaption, "Settings does not show SummaryPrivacyCopy.localSummariesUnsupportedCaption")
}
