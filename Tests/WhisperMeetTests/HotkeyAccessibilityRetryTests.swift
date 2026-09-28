import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F523 — Quick Dictation enabled before Accessibility is granted. The tap cannot be created, the
/// status asks for Accessibility, and granting it used to change nothing but the Settings row: the
/// tap is created only by the enable toggle and a trigger change, so the key stayed dead until one
/// of those or a relaunch.

/// Hands out the Grant poll's pauses one at a time: `sleep` waits until the test lets it go. No clock.
private final class PollGate: @unchecked Sendable {
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

    /// Pauses the poll has begun, released or not.
    var sleepsStarted: Int { lock.withLock { started } }
    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }

    func release() {
        let continuation = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        continuation?.resume()
    }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let notifications: NotificationCenter
    let cleanUp: () -> Void

    /// Enabled at launch with the tap failing, as it does without Accessibility.
    init() throws {
        let suite = "WhisperMeet.HotkeyAccessibilityRetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyAccessibilityRetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        let monitor = FakeHotkeyMonitor()
        monitor.startResult = false
        let notifications = NotificationCenter()
        self.monitor = monitor
        self.notifications = notifications
        controller = DictationController(
            defaults: defaults,
            engine: EmptyDictationEngine(),
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            textInjector: isolatedTextInjector(),
            activationNotifications: notifications,
            activateOnInit: true
        )
    }
}

/// The subject of each wait below is the value asserted after it, and 30 s is far past any host.
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
@Test("Coming back to WhisperMeet after granting Accessibility arms the trigger (F523)")
func returningToTheAppRetriesAFailedTrigger() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor) = (harness.controller, harness.monitor)
    try #require(controller.status != .idle, "the tap failed at launch, so the status must say so")
    let startsAtLaunch = monitor.startCount

    // Still not granted: coming to the front retries, and the status still asks for it.
    harness.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == startsAtLaunch + 1, "coming to the front did not retry the trigger's tap")
    #expect(controller.status != .idle)

    // Accessibility granted in System Settings; the user switches back to WhisperMeet. The
    // application posts this on the main thread, and the observer acts before `post` returns.
    monitor.startResult = true
    harness.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == startsAtLaunch + 2, "coming to the front did not retry the trigger's tap")
    #expect(controller.status == .idle)

    // Armed now, so later activations leave the working tap alone.
    harness.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == startsAtLaunch + 2, "a working tap was rebuilt on activation")
}

@MainActor
@Test("After Grant…, the trigger is armed as soon as Accessibility is granted (F523)")
func grantPollArmsTheTriggerOnceTrusted() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, monitor) = (harness.controller, harness.monitor)
    let gate = PollGate()
    var trusted = false
    var prompts = 0
    controller.accessibilityTrusted = { trusted }
    controller.promptForAccessibility = { prompts += 1 }
    controller.accessibilityPollSleep = { try await gate.sleep($0) }
    let startsAtLaunch = monitor.startCount

    controller.requestAccessibility()
    #expect(prompts == 1)

    // Not granted yet: a check passes without touching the tap.
    let firstPause = try await waitUntil { gate.isWaiting }
    try #require(firstPause, "Grant… started no poll")
    gate.release()
    let secondPause = try await waitUntil { gate.sleepsStarted == 2 }
    try #require(secondPause)
    #expect(monitor.startCount == startsAtLaunch)

    // Granted while the user is still in System Settings: the next check arms the trigger.
    trusted = true
    monitor.startResult = true
    gate.release()
    let rearmed = try await waitUntil { monitor.startCount > startsAtLaunch }
    #expect(rearmed, "the grant was never noticed")
    #expect(controller.status == .idle)
    // ...and the poll is over.
    let stopped = try await waitUntil { !controller.isAwaitingAccessibility }
    #expect(stopped)
    #expect(gate.sleepsStarted == 2)
}

@MainActor
@Test("The poll after Grant… stops on its own when Accessibility never comes (F523)")
func grantPollIsBounded() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let controller = harness.controller
    let gate = PollGate()
    controller.accessibilityTrusted = { false }
    controller.promptForAccessibility = {}
    controller.accessibilityPollSleep = { try await gate.sleep($0) }

    controller.requestAccessibility()
    for pause in 1...DictationController.accessibilityPollChecks {
        let paused = try await waitUntil { gate.sleepsStarted == pause && gate.isWaiting }
        try #require(paused, "pause \(pause) never began")
        gate.release()
    }
    let stopped = try await waitUntil { !controller.isAwaitingAccessibility }
    #expect(stopped, "the poll did not end after its last check")
    #expect(gate.sleepsStarted == DictationController.accessibilityPollChecks)
}
