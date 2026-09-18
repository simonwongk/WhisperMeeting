import Foundation
import Testing

// F294 — the presentation and the announcer are tested in WhisperCore by driving them directly,
// which cannot notice that nothing calls them. These pin the three call sites.

private func uncommentedSource(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent(path)
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")
}

@Test("The menu-bar menu is given the live recording health and renders its line (F294)")
func menuBarMenuReceivesRecordingHealth() throws {
    let source = try uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(source.contains("health: model.recordingHealth"))
    #expect(source.contains("if let healthLine = presentation.healthLine"))
    #expect(source.contains("model.recordingHealth?.overallStatus == .atRisk"))
}

@Test("The health tick feeds the announcer, and each recording starts with a fresh one (F294)")
func healthTickFeedsTheAnnouncer() throws {
    let source = try uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(source.contains("self.riskAnnouncer.announcement(for: snapshot)"))
    #expect(source.contains("self.postWindowlessAlert(announcement)"))
    #expect(source.contains("riskAnnouncer = RecordingRiskAnnouncer()"))
}
