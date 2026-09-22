import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F294 — the presentation and the announcer are tested in WhisperCore by driving them directly,
// which cannot notice that nothing calls them. These pin the three call sites.

@Test("The menu-bar menu is given the live recording health and renders its line (F294)")
func menuBarMenuReceivesRecordingHealth() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(source.contains("health: model.recordingHealth"))
    #expect(source.contains("if let healthLine = presentation.healthLine"))
    #expect(source.contains("model.isRecordingAtRisk"))
}

@Test("The health tick feeds the announcer, and each recording starts with a fresh one (F294)")
func healthTickFeedsTheAnnouncer() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(source.contains("self.riskAnnouncer.announcement(for: snapshot)"))
    #expect(source.contains("self.postWindowlessAlert(announcement)"))
    #expect(source.contains("riskAnnouncer = RecordingRiskAnnouncer()"))
}

// F337 — two rules for the same icon, and the tested one was not the one on screen.
// `MenuBarRecording.make` required `isRecording && !isStopping` precisely so a stale snapshot is
// ignored, while `AppEntry.menuBarSymbol` re-implemented it as `isRecordingActive &&
// health == .atRisk` — and `isRecordingActive` is true for `.starting` and `.stopping`. So while the
// app said "Finishing…" and the menu's own health line had been suppressed, the icon still showed
// the warning triangle from the last snapshot.

@MainActor
@Test("The menu-bar icon is not at risk once the recording is finishing (F337)")
func menuBarIconIsNotAtRiskWhileStopping() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F337-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F337.\(UUID().uuidString)")!)
    let dying = RecordingHealthSnapshot(
        microphoneLevel: RecordingAudioLevel(rms: 0, peak: 0),
        systemAudioLevel: RecordingAudioLevel(rms: 0, peak: 0),
        availableStorageBytes: nil, warnings: [.microphoneCaptureStopped]
    )
    model.setRecordingHealthForTesting(dying)

    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    #expect(model.isRecordingAtRisk, "a live recording losing audio is the one thing the icon must show")

    model.setRecordingStateForTesting(.stopping)
    #expect(!model.isRecordingAtRisk, "the snapshot is stale the moment the recording is finishing")
    // The menu's own health line already agreed; the icon did not.
    let presentation = MenuBarRecording.make(
        isRecording: model.isRecordingActive, isStopping: model.recordingState == .stopping,
        elapsedSeconds: 1, isMicrophoneBusy: false, hasActiveTranscription: false, health: dying
    )
    #expect(presentation.healthLine == nil)
}

@Test("The menu-bar icon reads the one shared at-risk rule (F337)")
func menuBarIconUsesTheSharedRule() throws {
    let entry = try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/WhisperMeet/AppEntry.swift"), encoding: .utf8)
    #expect(entry.contains("model.isRecordingAtRisk"))
    #expect(!entry.contains("model.recordingHealth?.overallStatus == .atRisk"),
            "the icon must not re-implement the rule the menu already has")
}
