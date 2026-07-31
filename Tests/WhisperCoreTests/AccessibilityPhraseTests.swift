import Testing
@testable import WhisperCore

/// F71 — exact spoken labels across statuses and durations.
@Test("Accessibility phrases render exact spoken strings")
func accessibilityPhrases() {
    #expect(AccessibilityPhrase.meetingRow(title: "Team sync", statusRaw: "completed", duration: 2520)
        == "Team sync, transcript ready, 42 minutes")
    #expect(AccessibilityPhrase.meetingRow(title: "Standup", statusRaw: "recorded", duration: 0)
        == "Standup, ready to transcribe")
    #expect(AccessibilityPhrase.meetingRow(title: "One", statusRaw: "processing", duration: 60)
        == "One, transcribing, 1 minute")

    #expect(AccessibilityPhrase.recordButton(isRecording: false, isBusy: false) == "Start recording")
    #expect(AccessibilityPhrase.recordButton(isRecording: true, isBusy: false) == "Stop recording")
    #expect(AccessibilityPhrase.recordButton(isRecording: false, isBusy: true) == "Recording controls unavailable")

    #expect(AccessibilityPhrase.marker(label: "Q3 plan", offset: 125) == "Marker Q3 plan at 02:05")
}
