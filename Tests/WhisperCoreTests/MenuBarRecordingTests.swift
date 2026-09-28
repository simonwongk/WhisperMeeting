import Testing
@testable import WhisperCore

/// F62 — the menu-bar recording presentation.
@Test("Menu bar recording presentation reflects idle / recording / stopping / transcribing")
func menuBarRecordingPresentation() {
    let idle = MenuBarRecording.make(
        isRecording: false, isStopping: false, elapsedSeconds: 0,
        canStartRecording: true, hasActiveTranscription: false
    )
    #expect(idle.startEnabled)
    #expect(!idle.stopEnabled)
    #expect(!idle.addMarkerEnabled)

    let recording = MenuBarRecording.make(
        isRecording: true, isStopping: false, elapsedSeconds: 323,
        canStartRecording: false, hasActiveTranscription: false
    )
    #expect(recording.statusTitle == "Recording 05:23")
    #expect(recording.stopEnabled)
    #expect(recording.addMarkerEnabled)
    #expect(recording.cancelNeedsConfirmation)
    #expect(!recording.startEnabled)

    let stopping = MenuBarRecording.make(
        isRecording: true, isStopping: true, elapsedSeconds: 400,
        canStartRecording: false, hasActiveTranscription: false
    )
    #expect(!stopping.startEnabled)
    #expect(!stopping.stopEnabled)
    #expect(!stopping.addMarkerEnabled)

    // F543: this case was called "importing" and passed a running TRANSCRIPTION, asserting Start was
    // greyed — the menu bar's bug written down as its spec. `startRecording()` does not refuse a
    // start during a transcription, and the record screen and ⌘R both offer one, so the menu does
    // too; the transcription shows in the status line instead.
    let transcribing = MenuBarRecording.make(
        isRecording: false, isStopping: false, elapsedSeconds: 0,
        canStartRecording: true, hasActiveTranscription: true
    )
    #expect(transcribing.statusTitle == "Transcribing…")
    #expect(transcribing.startEnabled)
    #expect(!transcribing.stopEnabled)

    // Start follows the shared rule and nothing else: an import (a refusal `startRecording()` makes
    // without a word) arrives here as `canStartRecording: false`.
    let importing = MenuBarRecording.make(
        isRecording: false, isStopping: false, elapsedSeconds: 0,
        canStartRecording: false, hasActiveTranscription: false
    )
    #expect(!importing.startEnabled)
    #expect(!importing.stopEnabled)
}
