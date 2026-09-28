import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F633 — a failed re-tap sets `status` to the tap error, and the pill's pending dismiss used to
/// write `.idle` over it 1–2 s later, so Settings showed a dead trigger as working. Second face: a
/// re-tap that fails under a live toggle capture (F584's rule 3) had already removed the old tap, so
/// no key could end that capture before the 120 s watchdog.

@MainActor
private final class HideCountingOverlay: DictationOverlayPresenting {
    private(set) var hides = 0
    private(set) var shown: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { shown.append(phase) }
    func update(level: Float) {}
    func hide() { hides += 1 }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let recorder: FakeDictationRecorder
    let overlay: HideCountingOverlay
    let cleanUp: () -> Void

    init(hotkey: DictationHotkey) throws {
        let suite = "WhisperMeet.HotkeyTapFailureStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyTapFailureStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")
        let monitor = FakeHotkeyMonitor()
        let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        let overlay = HideCountingOverlay()
        self.monitor = monitor
        self.recorder = recorder
        self.overlay = overlay
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: recorder,
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            // Never fires inside a test: each capture here ends on an edge or a change.
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        controller.announce = { _ in }
    }
}

/// Polls the value asserted after it; 30 s is far past any host.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private let tapFailure = DictationController.Status.error(DictationController.tapFailureMessage)

@MainActor
@Test("A trigger whose re-tap failed still reads as failed after the no-audio pill is dismissed (F633)")
func aFailedReTapSurvivesTheNoAudioDismiss() async throws {
    let harness = try Harness(hotkey: DictationHotkey(keyCode: 96, mode: .hold))
    defer { harness.cleanUp() }
    let (controller, monitor, recorder, overlay) = (harness.controller, harness.monitor, harness.recorder, harness.overlay)

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    recorder.stopError = MicDictationRecorder.RecorderError.noAudioCaptured
    monitor.onPressEnd?()
    try #require(controller.status == .idle, "nothing heard should settle at once, with its pill still up")
    let hidesBeforeDismiss = overlay.hides

    // In the pill's dismiss window the trigger is changed, and Accessibility has been revoked.
    monitor.startResult = false
    controller.hotkey = DictationHotkey(keyCode: 97, mode: .hold)
    try #require(controller.status == tapFailure)

    let dismissed = try await waitUntil { overlay.hides > hidesBeforeDismiss }
    try #require(dismissed, "the pill was never dismissed")
    #expect(controller.status == tapFailure, "the dismiss wrote over the tap failure: \(controller.status)")
}

@MainActor
@Test("A re-tap that fails under a live toggle dictation ends it, delivers it, then reads as failed (F633)")
func aReTapFailingUnderALiveCaptureEndsIt() async throws {
    let harness = try Harness(hotkey: DictationHotkey(keyCode: 96, mode: .toggle))
    defer { harness.cleanUp() }
    let (controller, monitor, recorder, overlay) = (harness.controller, harness.monitor, harness.recorder, harness.overlay)

    monitor.onPressStart?()
    try #require(controller.status == .listening)

    // Toggle to toggle takes over under the capture (F584 rule 3), and the new tap cannot be made.
    // `HotkeyMonitor.start` removes the old tap first, so F5 can no longer end this capture either.
    monitor.startResult = false
    controller.hotkey = DictationHotkey(keyCode: 97, mode: .toggle)
    #expect(recorder.stopCount == 1, "a capture no key can end was left listening")
    #expect(!recorder.isRecording)
    #expect(monitor.resetToggleCount >= 1, "toggle's on-state was left latched")

    let delivered = try await waitUntil { overlay.shown.last == .copied }
    try #require(delivered, "the capture was not delivered: \(controller.status)")
    #expect(controller.logStore.log.entries.first?.text == "dictated words")
    let hidesAfterDelivery = overlay.hides
    let dismissed = try await waitUntil { overlay.hides > hidesAfterDelivery }
    try #require(dismissed, "the pill was never dismissed")
    #expect(controller.status == tapFailure, "the trigger reads as working: \(controller.status)")
}
