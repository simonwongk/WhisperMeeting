import Testing
@testable import WhisperCore

// F294 — the recording-health banner lived only in the main window, so a user recording from the
// menu bar with no window open could not see "Microphone capture stopped". The menu-bar menu and
// its icon now carry it, and an at-risk transition is announced once. Decided 2026-09-18 under the
// user's delegation: the shape every menu-bar recorder uses — icon changes, the menu says why, one
// notification per problem rather than one per second.

private func snapshot(_ warnings: [RecordingHealthWarning]) -> RecordingHealthSnapshot {
    RecordingHealthSnapshot(
        microphoneLevel: RecordingAudioLevel(rms: 0.1, peak: 0.2),
        systemAudioLevel: RecordingAudioLevel(rms: 0.1, peak: 0.2),
        availableStorageBytes: nil,
        warnings: warnings
    )
}

private func menu(_ health: RecordingHealthSnapshot?, recording: Bool = true) -> MenuBarRecordingPresentation {
    MenuBarRecording.make(
        isRecording: recording, isStopping: false, elapsedSeconds: 10,
        isMicrophoneBusy: false, hasActiveTranscription: false, health: health
    )
}

@Test("A healthy recording adds no health line and keeps the recording symbol (F294)")
func healthyRecordingHasNoHealthLine() {
    #expect(menu(snapshot([])).healthLine == nil)
    #expect(menu(snapshot([])).symbol == "record.circle.fill")
    #expect(menu(nil).healthLine == nil)
}

@Test("An at-risk recording names its worst problem in the menu and changes the icon (F294)")
func atRiskRecordingIsNamedInTheMenu() {
    let presentation = menu(snapshot([.microphoneClipping, .microphoneCaptureStopped]))
    #expect(presentation.healthLine == "⚠︎ Microphone capture stopped")
    #expect(presentation.symbol == "exclamationmark.triangle.fill")
}

@Test("A caution is named in the menu but does not change the icon (F294)")
func cautionIsNamedWithoutChangingTheIcon() {
    let presentation = menu(snapshot([.microphoneClipping]))
    #expect(presentation.healthLine == "Microphone is clipping")
    #expect(presentation.symbol == "record.circle.fill")
}

@Test("Health from a recording that has ended is not shown (F294)")
func staleHealthIsNotShownWhenIdle() {
    let presentation = menu(snapshot([.lowStorage]), recording: false)
    #expect(presentation.healthLine == nil)
    #expect(presentation.symbol == "record.circle")
}

@Test("An at-risk problem is announced once, not once a second (F294)")
func atRiskIsAnnouncedOnce() {
    var announcer = RecordingRiskAnnouncer()
    #expect(announcer.announcement(for: snapshot([])) == nil)
    let first = announcer.announcement(for: snapshot([.microphoneCaptureStopped]))
    #expect(first == "Recording needs attention: Microphone capture stopped.")
    #expect(announcer.announcement(for: snapshot([.microphoneCaptureStopped])) == nil)
    // It clears and comes back within the same recording: still not repeated.
    #expect(announcer.announcement(for: snapshot([])) == nil)
    #expect(announcer.announcement(for: snapshot([.microphoneCaptureStopped])) == nil)
}

@Test("A second, different at-risk problem is announced; cautions never are (F294)")
func differentProblemsAreAnnouncedSeparately() {
    var announcer = RecordingRiskAnnouncer()
    _ = announcer.announcement(for: snapshot([.microphoneCaptureStopped]))
    #expect(announcer.announcement(for: snapshot([.microphoneCaptureStopped, .lowStorage]))
            == "Recording needs attention: Low storage — recording may stop soon.")
    #expect(announcer.announcement(for: snapshot([.microphoneClipping, .systemAudioNotDetected])) == nil)
}
