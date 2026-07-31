import Testing
@testable import WhisperCore

/// F62 — the menu-bar recording presentation.
@Test("Menu bar recording presentation reflects idle / recording / stopping / importing")
func menuBarRecordingPresentation() {
    let idle = MenuBarRecording.make(
        isRecording: false, isStopping: false, elapsedSeconds: 0,
        isMicrophoneBusy: false, hasActiveTranscription: false
    )
    #expect(idle.startEnabled)
    #expect(!idle.stopEnabled)
    #expect(!idle.addMarkerEnabled)

    let recording = MenuBarRecording.make(
        isRecording: true, isStopping: false, elapsedSeconds: 323,
        isMicrophoneBusy: false, hasActiveTranscription: false
    )
    #expect(recording.statusTitle == "Recording 05:23")
    #expect(recording.stopEnabled)
    #expect(recording.addMarkerEnabled)
    #expect(recording.cancelNeedsConfirmation)
    #expect(!recording.startEnabled)

    let stopping = MenuBarRecording.make(
        isRecording: true, isStopping: true, elapsedSeconds: 400,
        isMicrophoneBusy: false, hasActiveTranscription: false
    )
    #expect(!stopping.startEnabled)
    #expect(!stopping.stopEnabled)
    #expect(!stopping.addMarkerEnabled)

    let importing = MenuBarRecording.make(
        isRecording: false, isStopping: false, elapsedSeconds: 0,
        isMicrophoneBusy: false, hasActiveTranscription: true
    )
    #expect(!importing.startEnabled)
    #expect(!importing.stopEnabled)
}
