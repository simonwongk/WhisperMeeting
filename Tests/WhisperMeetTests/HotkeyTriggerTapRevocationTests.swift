import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F547, from its independent review. An F-key trigger's tap is active: every key-down and key-up in
/// the session waits on it. Other apps with that shape froze the whole keyboard when Accessibility
/// was revoked, because the tap re-enabled itself on disable and nothing re-checked the grant
/// (deskflow #9562, slovo #73), and revocation can arrive with no disable event (slovo #112). Here a
/// lost tap is re-armed through `start` — a new tap, refused without the grant — the grant is
/// re-checked by a probe while the active tap is armed, and a loss nobody can vouch for arms
/// listen-only. No test creates a tap or a probe: the monitor and the probe are fakes.

/// A monitor that arms an F-key the way `HotkeyMonitor.start` does, with Accessibility and Input
/// Monitoring as switches.
private final class GrantAwareMonitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?
    var onTriggerTapLost: ((TriggerTapLoss) -> Void)?
    var mayHoldTriggerBack = true
    /// Accessibility: whether an active tap can be created.
    var accessibilityGranted = true
    /// Input Monitoring: whether the listen-only fallback can be created without Accessibility.
    var inputMonitoringGranted = true
    private(set) var isHoldingTriggerBack = false
    private(set) var isArmedWithoutHoldingBack = false
    /// `mayHoldTriggerBack` at each `start`, in order.
    private(set) var starts: [Bool] = []

    func start(hotkey: DictationHotkey) -> Bool {
        starts.append(mayHoldTriggerBack)
        let fKey = HotkeyMonitor.tapKind(for: hotkey) == .holdsTriggerBack
        isHoldingTriggerBack = fKey && mayHoldTriggerBack && accessibilityGranted
        let listenOnly = !isHoldingTriggerBack && (accessibilityGranted || inputMonitoringGranted)
        isArmedWithoutHoldingBack = fKey && listenOnly
        return isHoldingTriggerBack || listenOnly
    }
    func stop() {
        isHoldingTriggerBack = false
        isArmedWithoutHoldingBack = false
    }
    func resetToggleState() {}

    /// The system disabled the active tap, as `triggerTapWasDisabled` reports it.
    func loseTap(_ loss: TriggerTapLoss) {
        onTriggerTapLost?(loss)
    }
}

/// Hands out the probe's pauses one at a time. No clock.
private final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    func sleep(_: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                started += 1
                waiting.append(continuation)
            }
        }
    }
    var pausesStarted: Int { lock.withLock { started } }
    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }
    func release() {
        let continuation = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        continuation?.resume()
    }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: GrantAwareMonitor
    let recorder: FakeDictationRecorder
    let notifications: NotificationCenter
    let gate: PauseGate
    let probe: ProbeSwitch
    let cleanUp: () -> Void

    init(hotkey: DictationHotkey = DictationHotkey(keyCode: 96, mode: .hold)) throws {
        let suite = "WhisperMeet.HotkeyTriggerTapRevocationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyTriggerTapRevocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(false, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")
        let monitor = GrantAwareMonitor()
        let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        let notifications = NotificationCenter()
        let gate = PauseGate()
        let probe = ProbeSwitch()
        self.monitor = monitor
        self.recorder = recorder
        self.notifications = notifications
        self.gate = gate
        self.probe = probe
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: recorder,
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activationNotifications: notifications,
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        controller.announce = { _ in }
        controller.activeTapProbe = { probe.check() }
        controller.activeTapCheckSleep = { try await gate.sleep($0) }
    }

    /// Dictation switched on: the first arm.
    func enable() {
        controller.setEnabled(true)
    }

    func comeToTheFront() {
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }
}

/// What the probe tap would find, and how often it was asked.
@MainActor
private final class ProbeSwitch {
    var canCreateActiveTap = true
    private(set) var checks = 0
    func check() -> Bool {
        checks += 1
        return canCreateActiveTap
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
@Test("A disabled active tap is re-armed as a new tap: without Accessibility it falls back to listen-only (F547)")
func aLostActiveTapIsRebuiltNotReEnabled() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor) = (harness.controller, harness.monitor)
    harness.enable()
    try #require(monitor.isHoldingTriggerBack)

    // Accessibility revoked; the system disables the tap.
    monitor.accessibilityGranted = false
    monitor.loseTap(.timeout)

    #expect(monitor.starts.count == 2, "the lost tap was not re-armed through start")
    #expect(!monitor.isHoldingTriggerBack, "an active tap is still armed without Accessibility")
    #expect(monitor.isArmedWithoutHoldingBack)
    #expect(controller.status == .idle, "listen-only still works with Input Monitoring")
    #expect(!controller.isCheckingActiveTap, "the probe kept running with no active tap to check")
}

@MainActor
@Test("A disabled active tap with neither grant left fails visibly, and a dictation it stranded is delivered (F547, F633)")
func aLostActiveTapWithNothingLeftFailsVisibly() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)
    harness.enable()
    monitor.onPressStart?()
    try #require(controller.status == .listening)

    monitor.accessibilityGranted = false
    monitor.inputMonitoringGranted = false
    monitor.loseTap(.timeout)

    #expect(recorder.stopCount == 1, "a capture no key can end was left listening")
    #expect(!monitor.isHoldingTriggerBack)
    let settled = try await waitUntil { controller.status == tapFailure }
    #expect(settled, "the dead trigger reads as \(controller.status)")
}

@MainActor
@Test("A tap lost to 'user input' is re-armed listen-only until WhisperMeet comes to the front (F547)")
func aTapLostToUserInputArmsListenOnlyUntilTheAppIsActive() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let monitor = harness.monitor
    harness.enable()

    monitor.loseTap(.userInput)
    #expect(monitor.starts.last == false, "re-armed holding the key back after a loss nobody explains")
    #expect(!monitor.isHoldingTriggerBack)
    #expect(monitor.isArmedWithoutHoldingBack)

    harness.comeToTheFront()
    #expect(monitor.starts.last == true)
    #expect(monitor.isHoldingTriggerBack, "coming back to WhisperMeet did not hold the key back again")
}

@MainActor
@Test("A third lost active tap since WhisperMeet was last in front is re-armed listen-only (F547)")
func aThirdLostTapArmsListenOnly() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let monitor = harness.monitor
    harness.enable()

    monitor.loseTap(.timeout)
    monitor.loseTap(.timeout)
    #expect(monitor.isHoldingTriggerBack, "two timeouts should still re-arm the active tap")
    monitor.loseTap(.timeout)
    #expect(monitor.starts.last == false)
    #expect(!monitor.isHoldingTriggerBack, "a tap the system keeps disabling was re-armed a third time")

    harness.comeToTheFront()
    #expect(monitor.isHoldingTriggerBack)
    monitor.loseTap(.timeout)
    #expect(monitor.isHoldingTriggerBack, "the count did not start again when WhisperMeet came to the front")
}

/// Revocation can come with no disable event at all (slovo #112), so while the active tap is armed
/// a probe asks once a second whether one could still be created.
@MainActor
@Test("Revoked Accessibility with no disable event is caught by the probe, which then stops (F547)")
func revocationWithoutADisableEventIsCaughtByTheProbe() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor, gate, probe) = (harness.controller, harness.monitor, harness.gate, harness.probe)
    harness.enable()
    #expect(controller.isCheckingActiveTap, "no check runs while the active tap is armed")

    let firstPause = try await waitUntil { gate.pausesStarted == 1 && gate.isWaiting }
    try #require(firstPause)
    gate.release()
    let secondPause = try await waitUntil { gate.pausesStarted == 2 && gate.isWaiting }
    try #require(secondPause)
    #expect(probe.checks == 1)
    #expect(monitor.starts.count == 1, "a healthy probe re-armed the trigger")

    probe.canCreateActiveTap = false
    monitor.accessibilityGranted = false
    gate.release()
    let rearmed = try await waitUntil { monitor.starts.count == 2 }
    try #require(rearmed, "the failed probe did not re-arm the trigger")
    #expect(!monitor.isHoldingTriggerBack)
    #expect(!controller.isCheckingActiveTap)
    #expect(gate.pausesStarted == 2, "the probe kept running after the active tap was gone")
}

@MainActor
@Test("Coming to the front re-checks an armed active tap (F547)")
func comingToTheFrontProbesTheActiveTap() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (monitor, probe) = (harness.monitor, harness.probe)
    harness.enable()

    harness.comeToTheFront()
    #expect(probe.checks == 1)
    #expect(monitor.starts.count == 1, "a healthy active tap was rebuilt on activation")

    probe.canCreateActiveTap = false
    monitor.accessibilityGranted = false
    harness.comeToTheFront()
    #expect(monitor.starts.count == 2)
    #expect(!monitor.isHoldingTriggerBack)
}

@MainActor
@Test("A modifier trigger has no active tap, so nothing probes (F547)")
func aModifierTriggerIsNeverProbed() throws {
    let harness = try Harness(hotkey: .rightOption)
    defer { harness.cleanUp() }
    harness.enable()

    #expect(!harness.monitor.isHoldingTriggerBack)
    #expect(!harness.controller.isCheckingActiveTap)
    harness.comeToTheFront()
    #expect(harness.probe.checks == 0)
    #expect(harness.gate.pausesStarted == 0)
}

@MainActor
@Test("Switching dictation off stops the probe (F547)")
func disablingStopsTheProbe() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    harness.enable()
    try #require(harness.controller.isCheckingActiveTap)

    harness.controller.setEnabled(false)
    #expect(!harness.controller.isCheckingActiveTap)
}
