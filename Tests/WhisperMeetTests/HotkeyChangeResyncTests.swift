import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F39 — changing the dictation trigger key must re-sync `status`/`hotkeyActive` from the re-tap
/// result instead of discarding it. Start enabled with a failed tap (status `.error`), then change
/// the key with the tap now succeeding, and assert the controller recovers to `.idle`.
@MainActor
@Test("Changing the dictation hotkey re-syncs status from the re-tap result")
func changingHotkeyResyncsStatus() async throws {
    let suite = "WhisperMeet.HotkeyChangeResyncTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HotkeyChangeResyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")

    let monitor = FakeHotkeyMonitor()
    monitor.startResult = false // first tap creation fails (no Accessibility) → status .error
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: temporaryDirectory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: temporaryDirectory),
        activateOnInit: true
    )

    // Enabled at launch without Accessibility: the tap failed, so the controller is in .error.
    #expect(controller.status != .idle)
    let startsAfterInit = monitor.startCount

    // Grant Accessibility (tap now succeeds), then change the trigger key.
    monitor.startResult = true
    controller.hotkey = DictationHotkey(keyCode: 100, mode: .hold)

    #expect(monitor.startCount == startsAfterInit + 1) // the key change re-tapped
    #expect(controller.status == .idle)                // ...and the result was applied (F39)
}
