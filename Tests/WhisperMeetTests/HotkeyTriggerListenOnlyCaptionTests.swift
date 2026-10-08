import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F684 — on the listen-only fallback (an F-key trigger whose active tap was refused: Accessibility
/// missing, Input Monitoring granted) Settings' caption still said the key was kept from the app in
/// front. Only the log and the orange Accessibility row said otherwise, and the key kept reaching
/// that app. The caption now follows the tap the controller actually armed.

private let f5: UInt16 = 96
private let rightOption: UInt16 = 61

@Test("The trigger caption says a listen-only F-key still reaches the app in front, and why (F684)")
func theCaptionSaysWhenAnFKeyIsOnlyListenedTo() {
    let hold = DictationHotkey(keyCode: f5, mode: .hold)
    let heldBack = DictationController.triggerKeyCaption(for: hold, isListenOnly: false, accessibilityGranted: true)
    #expect(heldBack.contains("does not receive it"))

    let refused = DictationController.triggerKeyCaption(for: hold, isListenOnly: true, accessibilityGranted: false)
    #expect(!refused.contains("does not receive it"), "a listen-only F-key is still said to be kept from the app")
    #expect(refused.contains("receives it too"))
    #expect(refused.contains("Accessibility"), "the caption does not say what would keep the key from the app")
    #expect(refused.hasPrefix("Hold this key to talk."))

    // Listen-only with the grant: a loss nobody could vouch for (F547). Nothing to grant.
    let unvouched = DictationController.triggerKeyCaption(for: hold, isListenOnly: true, accessibilityGranted: true)
    #expect(unvouched.contains("receives it too"))
    #expect(!unvouched.contains("Allow WhisperMeet"))
    #expect(unvouched.contains("next comes to the front"))

    let toggle = DictationController.triggerKeyCaption(
        for: DictationHotkey(keyCode: f5, mode: .toggle), isListenOnly: true, accessibilityGranted: false
    )
    #expect(toggle.hasPrefix("Press this key to start dictating, and again to stop."))

    // A modifier is always only listened to, and its caption already says it reaches the app.
    let modifier = DictationController.triggerKeyCaption(
        for: DictationHotkey(keyCode: rightOption, mode: .hold), isListenOnly: false, accessibilityGranted: true
    )
    #expect(modifier.contains("A modifier key still reaches the app you are typing in"))
}

/// A monitor that is already running the stored F-key listen-only — the state the controller
/// starts from in a test built with `activateOnInit: false` — and whose next `start` holds the key
/// back or not, as the test says.
private final class ListenOnlyMonitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?
    var nextStartHoldsBack = false
    private(set) var isArmedWithoutHoldingBack = true
    private(set) var startCount = 0

    func start(hotkey: DictationHotkey) -> Bool {
        startCount += 1
        isArmedWithoutHoldingBack = !nextStartHoldsBack
        return true
    }
    func stop() { isArmedWithoutHoldingBack = false }
    func resetToggleState() {}
}

@MainActor
@Test("Settings' caption follows the tap armed: listen-only until Accessibility is granted, then held back (F684)")
func theControllerCaptionFollowsTheArmedTap() throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HotkeyTriggerListenOnlyCaptionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(try JSONEncoder().encode(DictationHotkey(keyCode: f5, mode: .hold)), forKey: "dictationHotkey")
    let monitor = ListenOnlyMonitor()
    let notifications = NotificationCenter()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activationNotifications: notifications,
        activateOnInit: false
    )
    var trusted = false
    controller.accessibilityTrusted = { trusted }

    // Coming to the front re-arms a listen-only F-key (F547); without Accessibility it stays so.
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try #require(monitor.startCount == 1)
    #expect(controller.isTriggerListenOnly, "the controller does not know the trigger is only listened to")
    #expect(controller.triggerKeyCaption.contains("receives it too"), "Settings still says the key is kept from the app")
    #expect(controller.triggerKeyCaption.contains("Allow WhisperMeet under Accessibility"))

    // Granted; the next arm holds the key back, and the caption says so again.
    trusted = true
    monitor.nextStartHoldsBack = true
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try #require(monitor.startCount == 2)
    #expect(!controller.isTriggerListenOnly)
    #expect(controller.triggerKeyCaption.contains("does not receive it"))
}
