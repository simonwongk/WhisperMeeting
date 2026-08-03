import Foundation
import Testing
@testable import WhisperMeet

@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cancel-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F139.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

// F139 — the ⌘ Cancel command (and the button) route through a confirmation, and never prompt or cancel
// when there is nothing to cancel (idle) — the state guard that also blocks a cancel racing finalization.
@MainActor
@Test("Cancel confirmation is not offered when idle, and cancel is a no-op then (F139)")
func cancelGuardWhenIdle() async {
    let model = makeModel()
    #expect(model.canCancelRecording == false)          // idle → not cancellable

    model.requestCancelConfirmation()
    #expect(model.isConfirmingCancellation == false)    // no prompt when nothing is recording

    await model.cancelRecording()                        // no-op, no crash / state change
    #expect(model.recordingState == .idle)
}
