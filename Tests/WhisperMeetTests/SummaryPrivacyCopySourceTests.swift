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

// F794 — the check above reads ContentView alone, and F566's first draft put the same false claim in an
// AppModel alert ("Choose Claude in Settings to summarize on this Mac"). This one reads every string
// literal in both targets' sources, comments stripped (F285): none that names Claude may say "on this
// Mac". A literal split with `+` across lines is read whole, and so is a multi-line literal.
@Test("No string literal in the app's sources says a Claude summary happens on this Mac (F794)")
func noSourceLiteralPutsClaudeOnThisMac() throws {
    var offenders: [String] = []
    for directory in ["Sources/WhisperMeet", "Sources/WhisperCore"] {
        for url in try SourceAssertion.swiftFileURLs(under: directory) {
            let source = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
            for literal in stringLiterals(in: source) where literal.contains("Claude") && literal.contains("on this Mac") {
                offenders.append("\(url.lastPathComponent): \(literal)")
            }
        }
    }
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test("The literal reader finds a claim split with + across lines, and inside a multi-line literal (F794 self-check)")
func theLiteralReaderSeesSplitAndMultiLineClaims() {
    let split = "let m = \"Choose Claude in Settings \"\n    + \"to summarize on this Mac.\""
    #expect(stringLiterals(in: split).contains { $0.contains("Claude") && $0.contains("on this Mac") })
    let block = "let m = \"\"\"\nClaude summaries\nstay on this Mac.\n\"\"\""
    #expect(stringLiterals(in: block).contains { $0.contains("Claude") && $0.contains("on this Mac") })
    let apart = "let m = local ? \"Summarizing on this Mac…\" : \"Summarizing with Claude…\""
    #expect(!stringLiterals(in: apart).contains { $0.contains("Claude") && $0.contains("on this Mac") })
}

/// The contents of every string literal in `source`: multi-line literals whole, and single-line ones
/// joined where `+` concatenates them, so a sentence split across lines is read as one.
private func stringLiterals(in source: String) -> [String] {
    let blocks = try! NSRegularExpression(pattern: #"\"\"\"([\s\S]*?)\"\"\""#)
    let whole = source as NSString
    var literals = blocks.matches(in: source, range: NSRange(location: 0, length: whole.length))
        .map { whole.substring(with: $0.range(at: 1)) }
    let rest = blocks.stringByReplacingMatches(in: source, range: NSRange(location: 0, length: whole.length), withTemplate: "")
    let joined = try! NSRegularExpression(pattern: #"\"\s*\+\s*\""#)
        .stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    let single = try! NSRegularExpression(pattern: #"\"((?:[^\"\\\n]|\\.)*)\""#)
    let text = joined as NSString
    literals += single.matches(in: joined, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
    return literals
}
