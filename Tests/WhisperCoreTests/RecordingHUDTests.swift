import Foundation
import Testing
@testable import WhisperCore

/// F74 — the compact recording HUD state.
@Test("Recording HUD surfaces the most-severe warning and formats elapsed time")
func recordingHUDState() {
    let health = RecordingHealthSnapshot(
        microphoneLevel: .silent,
        systemAudioLevel: .silent,
        availableStorageBytes: nil,
        warnings: [.systemAudioNotDetected, .lowStorage] // lowStorage is more severe
    )

    let state = RecordingHUD.make(
        isRecording: true, isStopping: false, elapsedSeconds: 323, health: health, level: 0.5
    )
    #expect(state.elapsedText == "5:23")
    #expect(state.topWarning == "Low storage — recording may stop soon")
    #expect(state.statusLine == "Recording")

    let stopping = RecordingHUD.make(
        isRecording: true, isStopping: true, elapsedSeconds: 10, health: nil, level: 0
    )
    #expect(stopping.statusLine == "Finishing…")
    #expect(stopping.topWarning == nil)

    // Present only while recording AND backgrounded.
    #expect(!RecordingHUD.shouldPresent(isRecording: true, appIsActive: true))
    #expect(RecordingHUD.shouldPresent(isRecording: true, appIsActive: false))
    #expect(!RecordingHUD.shouldPresent(isRecording: false, appIsActive: false))
}
