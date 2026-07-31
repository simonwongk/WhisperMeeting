import Testing
@testable import WhisperCore

/// F57 — content + gating for the local transcription-finished notification.
@Test("Transcription notification content and gating rules")
func transcriptionNotificationRules() {
    let completed = TranscriptionNotification.content(title: "Team Sync", outcome: .completed, segmentCount: 12)
    #expect(completed?.title == "Transcript ready")
    #expect(completed?.body == "Team Sync") // body carries only the meeting title

    let failed = TranscriptionNotification.content(title: "Team Sync", outcome: .failed, segmentCount: 0)
    #expect(failed?.title == "Transcription failed")
    #expect(failed?.body.contains("Team Sync") == true)

    #expect(TranscriptionNotification.content(title: "x", outcome: .cancelled, segmentCount: 0) == nil)

    // Suppressed while frontmost; shown when backgrounded; never for a cancellation.
    #expect(!TranscriptionNotification.shouldNotify(outcome: .completed, appIsActive: true))
    #expect(TranscriptionNotification.shouldNotify(outcome: .completed, appIsActive: false))
    #expect(!TranscriptionNotification.shouldNotify(outcome: .cancelled, appIsActive: false))
}
