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

    // F87 — the level-meter phrase rounds to whole percent and clamps out-of-range levels.
    #expect(AccessibilityPhrase.levelMeter(channel: "Microphone", level: 0.42)
        == "Microphone level 42 percent")
    #expect(AccessibilityPhrase.levelMeter(channel: "System audio", level: 1.7)
        == "System audio level 100 percent")
    #expect(AccessibilityPhrase.levelMeter(channel: "Live input", level: -0.3)
        == "Live input level 0 percent")
}
