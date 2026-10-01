import Foundation

/// Summary copy whose privacy claim depends on the selected engine (F555).
///
/// Two captions said the Claude summary path stays on this Mac. The template picker sits in the same
/// row as "Summarize with Claude", and its tooltip ended "Everything stays on this Mac." for both
/// engines. On a Mac that cannot run local summaries, Settings said "Choose Claude to summarize on
/// this Mac." Claude summaries are the one feature that leaves this Mac — the confirmation before a
/// Claude summary says so — so a caption that says otherwise is a false privacy claim.
///
/// These are values rather than literals in a SwiftUI body because the `WhisperMeet` target has no
/// view-render harness (F174): `WhisperCoreTests/SummaryPrivacyCopyTests.swift` pins the wording and
/// `summaryPrivacyCopyIsWhatContentViewShows` pins that the view shows it.
public enum SummaryPrivacyCopy {
    /// The template picker's tooltip. The picker is shown for both engines, so only the local engine's
    /// tooltip says the summary stays on this Mac.
    public static func templatePickerHelp(for engine: SummarizationEngine) -> String {
        let purpose = "Choose a template that shapes the summary's structure for this kind of meeting."
        switch engine {
        case .local:
            return purpose + " Local summaries stay on this Mac."
        case .claude:
            return purpose + " With Claude selected, summarizing sends the transcript to Anthropic."
        }
    }

    /// Settings ▸ Summaries, when the local engine is selected on a Mac that cannot run it.
    public static let localSummariesUnsupportedCaption =
        "Local summaries require an Apple-silicon Mac. To summarize anyway, choose Claude, which sends the transcript to Anthropic's cloud API."
}
