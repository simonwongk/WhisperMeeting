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

/// Fires the capture watchdog for the first armed capture only; later captures never fire (so a
/// freshly-started capture stays `.listening`).
private final class FirstArmFiresOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func isFirst() -> Bool { lock.withLock { count += 1; return count == 1 } }
}

/// F78 — after the F50 watchdog auto-finalizes a toggle-mode capture (no user end-edge), the next
/// press must START a fresh capture, not fire a swallowed end edge.
@MainActor
@Test("After the capture watchdog auto-finalizes a toggle dictation, the next press starts a new one")
func watchdogFinalizeDoesNotInvertToggle() async throws {
    let suite = "WhisperMeet.DictationToggleRecoveryTests.watchdog.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationToggleWatchdogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let monitor = HotkeyMonitor(hotkey: DictationHotkey(keyCode: 96, mode: .toggle))
    let recorder = FakeDictationRecorder(
        outputURL: temporaryDirectory.appendingPathComponent("capture.wav")
    )
    // A too-short clip so the first watchdog finalize discards straight back to idle (no transcribe
    // pipeline / dismiss timer), keeping the test deterministic.
    recorder.stopDuration = 0.1
    let firstArm = FirstArmFiresOnce()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureTimeout: .seconds(120),
        // Only the first armed capture's watchdog fires; the second stays pending.
        captureSleep: { _ in if !firstArm.isFirst() { try await Task.sleep(for: .seconds(3600)) } },
        activateOnInit: false
    )

    // First toggle press → capture starts → watchdog fires immediately → discard back to idle.
    monitor.handleKeyStateChange(true)
    for _ in 0..<60 where controller.status != .idle {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.status == .idle)
    #expect(!recorder.isRecording)

    // Next press must START a new capture, not fire a swallowed end edge.
    monitor.handleKeyStateChange(false)
    monitor.handleKeyStateChange(true)
    for _ in 0..<60 where controller.status != .listening {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(recorder.isRecording)
    #expect(controller.status == .listening)
}

/// F37 — dictation is paused while a meeting recognition runtime installs (CPU/memory contention),
/// then resumes, with a reason distinct from "microphone busy".
@MainActor
@Test("Dictation is paused while a recognition runtime is installing, then resumes")
func dictationPausesDuringRuntimeInstall() async throws {
    let suite = "WhisperMeet.DictationInstallGuardTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationInstallGuardTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let recorder = FakeDictationRecorder(
        outputURL: temporaryDirectory.appendingPathComponent("capture.wav")
    )
    var installing = true
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: HotkeyMonitor(hotkey: DictationHotkey(keyCode: 96, mode: .hold)),
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        activateOnInit: false
    )
    controller.configureRuntimeInstalling { installing }

    // While installing, a press is refused (not a microphone conflict).
    controller.handlePressStart()
    #expect(controller.status != .listening)
    #expect(!recorder.isRecording)

    // Once the install finishes, dictation resumes.
    installing = false
    controller.handlePressStart()
    #expect(controller.status == .listening)
    #expect(recorder.isRecording)
}
