import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F689 — after F547, everything that answers a revoked Accessibility grant under an armed F-key
/// trigger waited for the main thread: the once-a-second probe was a main-actor task, and removing
/// the active tap — which every key-down and key-up in the session waits on — was main-thread work.
/// App Nap (WhisperMeet held no activity while idle) or a main-thread stall (F538) delayed all of it.
/// The probe now runs off the main thread and lets go of the tap there; an App Nap exemption is held
/// while the active tap is armed. No test creates a tap: the monitor, the probe and its pauses are
/// fakes, and "the main thread is blocked" is a test spinning on it.

/// Counts what the off-main check does, from whatever thread it does it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var offMain = 0
    func hit() {
        lock.withLock {
            value += 1
            if !Thread.isMainThread { offMain += 1 }
        }
    }
    var count: Int { lock.withLock { value } }
    var offMainCount: Int { lock.withLock { offMain } }
}

/// What the probe tap would find, and how often it was asked; locked, since it is asked off main.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var asked = 0
    func set(_ canCreate: Bool) { lock.withLock { allowed = canCreate } }
    var checks: Int { lock.withLock { asked } }
    func check() -> Bool { lock.withLock { asked += 1; return allowed } }
}

/// An F-key trigger armed the way `HotkeyMonitor.start` arms it, with Accessibility as a switch, and
/// a disarmer that records the thread it ran on.
private final class Monitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?
    var onTriggerTapLost: ((TriggerTapLoss) -> Void)?
    var mayHoldTriggerBack = true
    var accessibilityGranted = true
    private(set) var isHoldingTriggerBack = false
    private(set) var isArmedWithoutHoldingBack = false
    private(set) var starts = 0
    let disarms = Counter()
    var activeTapDisarmer: @Sendable () -> Void { { [disarms] in disarms.hit() } }

    func start(hotkey: DictationHotkey) -> Bool {
        starts += 1
        let fKey = HotkeyMonitor.tapKind(for: hotkey) == .holdsTriggerBack
        isHoldingTriggerBack = fKey && mayHoldTriggerBack && accessibilityGranted
        isArmedWithoutHoldingBack = fKey && !isHoldingTriggerBack
        return true
    }
    func stop() {
        isHoldingTriggerBack = false
        isArmedWithoutHoldingBack = false
    }
    func resetToggleState() {}
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

private final class ExemptionToken: NSObject {}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor = Monitor()
    let probe = Probe()
    let gate = PauseGate()
    let notifications = NotificationCenter()
    let begun = Counter()
    let ended = Counter()
    let cleanUp: () -> Void

    init(hotkey: DictationHotkey = DictationHotkey(keyCode: 96, mode: .hold)) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyTriggerTapOffMainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(false, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
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
        let (probe, gate, begun, ended) = (probe, gate, begun, ended)
        controller.activeTapProbe = { probe.check() }
        controller.activeTapCheckSleep = { try await gate.sleep($0) }
        controller.beginAppNapExemption = { _ in begun.hit(); return ExemptionToken() }
        controller.endAppNapExemption = { _ in ended.hit() }
        let controller = self.controller
        cleanUp = {
            controller.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func comeToTheFront() {
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }
}

/// Polls the value asserted after it, awaiting between looks; 30 s is far past any host.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
@Test("A revoked grant is caught, and the active tap let go, while the main thread is blocked (F689)")
func revocationIsAnsweredWithTheMainThreadBlocked() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor, probe, gate) = (harness.controller, harness.monitor, harness.probe, harness.gate)
    controller.setEnabled(true)
    try #require(monitor.isHoldingTriggerBack)
    let waiting = try await waitUntil { gate.pausesStarted == 1 && gate.isWaiting }
    try #require(waiting, "the check never started its first pause")

    // Accessibility revoked with no disable event (slovo #112). Then the main thread stalls — App
    // Nap or a slow Ask ranking (F538) — and is not given back until the tap has been let go or
    // ten seconds have passed. Nothing here awaits, so nothing else can run on this thread.
    probe.set(false)
    monitor.accessibilityGranted = false
    gate.release()
    let blockedUntil = Date().addingTimeInterval(10)
    while monitor.disarms.count == 0, Date() < blockedUntil { usleep(1_000) }
    let disarmedWhileBlocked = monitor.disarms.count
    let probedWhileBlocked = probe.checks

    #expect(probedWhileBlocked == 1, "the probe waited for the main thread")
    #expect(disarmedWhileBlocked == 1, "the active tap was not let go until the main thread was free")
    #expect(monitor.disarms.offMainCount == 1, "the tap was let go on the main thread")

    // Once the main thread is free, the trigger is re-armed without the active tap, as F547's was.
    let rearmed = try await waitUntil { monitor.starts == 2 }
    try #require(rearmed, "the trigger was never re-armed after the revocation")
    #expect(!monitor.isHoldingTriggerBack)
    #expect(monitor.isArmedWithoutHoldingBack)
    #expect(!controller.isCheckingActiveTap)
}

@MainActor
@Test("A probe that still passes lets nothing go and keeps checking (F689 control)")
func aPassingProbeDisarmsNothing() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor, gate) = (harness.controller, harness.monitor, harness.gate)
    controller.setEnabled(true)
    for pause in 1...3 {
        let waiting = try await waitUntil { gate.pausesStarted == pause && gate.isWaiting }
        try #require(waiting, "pause \(pause) never started")
        gate.release()
    }
    let fourth = try await waitUntil { gate.pausesStarted == 4 && gate.isWaiting }
    try #require(fourth)
    #expect(harness.probe.checks == 3)
    #expect(monitor.disarms.count == 0)
    #expect(monitor.starts == 1)
    #expect(controller.isCheckingActiveTap)
}

@MainActor
@Test("An App Nap exemption is held exactly while an F-key trigger's active tap is armed (F689)")
func appNapExemptionFollowsTheActiveTap() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor) = (harness.controller, harness.monitor)

    controller.setEnabled(true)
    #expect(harness.begun.count == 1)
    #expect(controller.isHoldingAppNapExemption)

    // Lost to "user input": re-armed listen-only (F547), so nothing is held back and nothing is held.
    monitor.onTriggerTapLost?(.userInput)
    #expect(!monitor.isHoldingTriggerBack)
    #expect(harness.ended.count == 1)
    #expect(!controller.isHoldingAppNapExemption)

    harness.comeToTheFront()
    #expect(monitor.isHoldingTriggerBack)
    #expect(harness.begun.count == 2)

    controller.setEnabled(false)
    #expect(harness.ended.count == 2)
    #expect(!controller.isHoldingAppNapExemption)
}

@MainActor
@Test("A modifier trigger, which has no active tap, takes no App Nap exemption (F689)")
func aModifierTriggerTakesNoExemption() throws {
    let harness = try Harness(hotkey: .rightOption)
    defer { harness.cleanUp() }
    harness.controller.setEnabled(true)
    #expect(harness.begun.count == 0)
    #expect(!harness.controller.isHoldingAppNapExemption)
}

@Test("The real monitor arms its any-thread switch with the active tap, and its own removal goes through it (F689)")
func theRealMonitorRoutesItsActiveTapThroughTheSwitch() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/HotkeyMonitor.swift")
    #expect(source.contains("activeTapSwitch.arm(port: port, source: source)"))
    #expect(source.contains("var activeTapDisarmer: @Sendable () -> Void { { [activeTapSwitch] in activeTapSwitch.disarm() } }"))
    // `removeTap` lets go through the switch, so a tap the probe already let go of is not torn down twice.
    let removeTap = try #require(source.range(of: "private func removeTap()"))
    let body = source[removeTap.upperBound...].prefix(900)
    #expect(body.contains("activeTapSwitch.disarm()"))
    #expect(!body.contains("CFMachPortInvalidate(triggerTap.port)"))
}
