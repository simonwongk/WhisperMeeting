import Foundation
import Testing
@testable import WhisperMeet

// F970 — the per-channel chip cannot be rendered here (F174), so its wiring is pinned as source,
// comments stripped (F285): the row asks `RecordingChannelRowState.make` with the channel, the
// snapshot and the meter's activity, and keeps no wording of its own.

@Test("The per-channel chip takes its words and tone from RecordingChannelRowState (F970)")
func theChannelRowReadsTheCoreState() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(content.range(of: "private struct RecordingChannelHealthRow: View {"))
    let end = try #require(content.range(of: "struct SettingsView: View {", range: start.upperBound..<content.endIndex))
    let row = content[start.upperBound..<end.lowerBound]
    #expect(row.contains("RecordingChannelRowState.make(channel: channel, health: health, isActive: isActive)"), "\(row)")
    #expect(row.contains("meter.snapshot.microphoneActive") && row.contains("meter.snapshot.systemAudioActive"))
    for literal in ["\"Silent\"", "\"Not being saved\"", "\"No audio for 3s+\"", "\"Receiving audio\""] {
        #expect(!row.contains(literal), "the row words a state itself: \(literal)")
    }
}
