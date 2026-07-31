import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F38 — a real `HotkeyMonitor` in toggle mode, wired to the controller. A first press is refused
/// (microphone busy); the fix must clear the monitor's latched toggle so the user's NEXT press
/// still starts capture instead of firing a no-op end edge.
@MainActor
@Test("A refused toggle-mode start does not invert the hotkey; the next press still starts capture")
func refusedToggleStartStillStartsOnNextPress() async throws {
    let suite = "WhisperMeet.DictationToggleRecoveryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationToggleRecoveryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let monitor = HotkeyMonitor(hotkey: DictationHotkey(keyCode: 96, mode: .toggle))
    let recorder = FakeDictationRecorder(
        outputURL: temporaryDirectory.appendingPathComponent("capture.wav")
    )
    var microphoneBusy = true
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureTimeout: .seconds(120),
        // A watchdog that never fires within the test window, so a started capture stays `.listening`
        // (this test is about the toggle edge, not the F50 finalize-on-timeout path).
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        activateOnInit: false
    )
    controller.configure(isMicrophoneBusy: { microphoneBusy })

    // First toggle-down edge: refused because the microphone is busy (e.g. a meeting is recording).
    monitor.handleKeyStateChange(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(!recorder.isRecording)

    // The meeting ends; the user presses the toggle again (key-up, then key-down).
    microphoneBusy = false
    monitor.handleKeyStateChange(false)
    monitor.handleKeyStateChange(true)
    for _ in 0..<40 where controller.status != .listening {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(recorder.isRecording)
    #expect(controller.status == .listening)
}
