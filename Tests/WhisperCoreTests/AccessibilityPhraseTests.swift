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

// F220 — VoiceOver is where an anonymous cluster label is most likely to be mistaken for an identity
// claim: the chip's words are gone and only the spoken sentence remains. `AccessibilityPhrase.swift:4`
// binds the rule ("never implies identified speakers"), so the phrase has to carry "inferred" itself.
// These are genuinely red against the current tree: `AccessibilityPhrase.speakerLabel` does not exist,
// so this file does not compile.

@Test("A spoken speaker label says the label was inferred, before the words it covers (F220)")
func speakerLabelPhraseSaysInferred() {
    #expect(AccessibilityPhrase.speakerLabel("Speaker 2", offset: 125, text: "we should ship it")
        == "Speaker 2, inferred, 02:05, we should ship it")
    // A label the reader typed is still a guess about voices, so it is spoken exactly the same way.
    #expect(AccessibilityPhrase.speakerLabel("Nadia", offset: 0, text: "morning")
        == "Nadia, inferred, 00:00, morning")
}

@Test("No spoken speaker label ever claims a person was recognized or identified (F220)")
func speakerLabelPhraseNeverClaimsIdentity() {
    let spoken = [
        AccessibilityPhrase.speakerLabel("Speaker 1", offset: 0, text: "hello"),
        AccessibilityPhrase.speakerLabel("Overlapping voices", offset: 61, text: "…"),
        AccessibilityPhrase.speakerLabel("Unclear which voice", offset: 3_600, text: "…")
    ]
    for phrase in spoken {
        let lowered = phrase.lowercased()
        for word in ["recognized", "recognised", "identified", "verified", "voiceprint", "who spoke"] {
            #expect(!lowered.contains(word), "spoken label claims identity with “\(word)”: \(phrase)")
        }
        #expect(lowered.contains("inferred"), "spoken label omits “inferred”: \(phrase)")
    }
}
