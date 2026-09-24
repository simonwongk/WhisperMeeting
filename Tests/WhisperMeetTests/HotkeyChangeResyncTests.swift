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
        textInjector: isolatedTextInjector(),
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

/// Lets the capture watchdog's sleep end when the test says so, instead of after 120 s.
private final class WatchdogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_: Duration) async throws {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting.removeAll() }
            return waiting
        }
        pending.forEach { $0.resume() }
    }
}

/// F446 — Settings' "Change" hears the trigger key itself, so choosing the key you are holding
/// re-applies the hotkey in the middle of the dictation that press started. That used to rebuild the
/// tap (forgetting the held key) and set `status = .idle` with the microphone still running, which
/// also disarmed the one backstop left: the capture watchdog finalizes only a `.listening` status.
@MainActor
@Test("Re-choosing the trigger mid-dictation leaves the capture listening and watched (F446)")
func rechoosingTheTriggerMidDictationKeepsTheCaptureWatched() async throws {
    let suite = "WhisperMeet.HotkeyChangeResyncTests.midCapture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HotkeyChangeResyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let monitor = FakeHotkeyMonitor()
    let recorder = FakeDictationRecorder(outputURL: temporaryDirectory.appendingPathComponent("c.wav"))
    let watchdog = WatchdogGate()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureSleep: { try await watchdog.sleep($0) },
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    let tapsBefore = monitor.startCount

    // The same key again: nothing about the trigger changed, so the tap under the held key stays.
    controller.hotkey = controller.hotkey
    #expect(monitor.startCount == tapsBefore)
    #expect(controller.status == .listening)
    #expect(controller.isActive)

    // A different key does need a new tap, but the dictation in flight still owns `status`.
    controller.hotkey = DictationHotkey(keyCode: 100, mode: .hold)
    #expect(monitor.startCount == tapsBefore + 1)
    #expect(controller.status == .listening)
    #expect(controller.isActive)

    // And the backstop still works: when the watchdog fires, the capture is finalized.
    watchdog.open()
    for _ in 0..<500 where recorder.isRecording {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recorder.stopCount == 1)
    #expect(!recorder.isRecording)
}
