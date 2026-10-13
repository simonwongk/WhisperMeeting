import Foundation
import Testing
@testable import WhisperMeet

// F959 — the record screen's health panel cannot be rendered here (F174), so the warning it leads
// with is pinned as source, comments stripped (F285): `statusReason` asks
// `RecordingHUD.leadingWarning(in:)`, whose rank order the WhisperCore tests check, and no longer
// reads `health.warnings.first`, the monitor's append order.

@Test("The health panel leads with the worst warning by rank, through the one selector every surface uses (F959)")
func thePanelLeadsWithTheWorstWarning() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(content.range(of: "private func statusReason(_ health: RecordingHealthSnapshot) -> String {"))
    let end = try #require(content.range(of: "private func ", range: start.upperBound..<content.endIndex))
    let body = content[start.upperBound..<end.lowerBound]
    #expect(body.contains("RecordingHUD.leadingWarning(in: health.warnings)"), "\(body)")
    #expect(!body.contains("warnings.first"), "the panel reads the monitor's append order, not the rank: \(body)")
}
