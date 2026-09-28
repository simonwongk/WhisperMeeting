import Testing
@testable import WhisperCore

// F543 — one rule for every Start Recording control.

@Test("Start is offered exactly when startRecording would not refuse it silently (F543)")
func recordingStartRuleTruthTable() {
    #expect(RecordingStartRule.isEnabled(isIdle: true, isImporting: false, isMicrophoneBusy: false,
                                         isInstallingRecognitionRuntime: false))
    #expect(!RecordingStartRule.isEnabled(isIdle: false, isImporting: false, isMicrophoneBusy: false,
                                          isInstallingRecognitionRuntime: false))
    #expect(!RecordingStartRule.isEnabled(isIdle: true, isImporting: true, isMicrophoneBusy: false,
                                          isInstallingRecognitionRuntime: false))
    #expect(!RecordingStartRule.isEnabled(isIdle: true, isImporting: false, isMicrophoneBusy: true,
                                          isInstallingRecognitionRuntime: false))
    #expect(!RecordingStartRule.isEnabled(isIdle: true, isImporting: false, isMicrophoneBusy: false,
                                          isInstallingRecognitionRuntime: true))
}

@Test("⌘R is greyed exactly when there is nothing to stop and Start is not offered (F543)")
func toggleRecordingFollowsTheStartRule() throws {
    let toggle = try #require(CommandCatalog.all.first { $0.id == "toggleRecording" })
    // Idle and startable: ⌘R starts.
    #expect(toggle.enablement.isEnabled(AppCommandState(isRecording: false, canStartRecording: true)))
    // Recording: ⌘R stops, whatever the start rule says.
    #expect(toggle.enablement.isEnabled(AppCommandState(isRecording: true, canStartRecording: false)))
    // Idle but not startable (an import, a preflight test): ⌘R used to stay live and do nothing.
    #expect(!toggle.enablement.isEnabled(AppCommandState(isRecording: false, canStartRecording: false)))
    // A transcription is not a reason to refuse a start.
    #expect(toggle.enablement.isEnabled(AppCommandState(isRecording: false, isTranscribing: true, canStartRecording: true)))
}
