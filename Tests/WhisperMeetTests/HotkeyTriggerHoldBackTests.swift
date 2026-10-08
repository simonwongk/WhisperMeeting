import AppKit
import CoreGraphics
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F547 — an F-key trigger reached the app in front: the tap was listen-only, so holding F5 to talk
/// in Terminal typed an escape sequence per autorepeat, and F6/F7 stepped Xcode's debugger. An F-key
/// trigger's tap now holds the key back. These call the tap's own callback with real `CGEvent`s and
/// no tap, which would need Accessibility and hear the keyboard of whoever runs the suite; a `nil`
/// return is the event kept from the app ("NULL if the event is to be deleted", CGEventTypes.h).

/// Counts the edges the monitor dispatches. Lock-guarded: the monitor dispatches on the main queue.
private final class EdgeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var ends = 0

    func start() { lock.withLock { starts += 1 } }
    func end() { lock.withLock { ends += 1 } }
    var startCount: Int { lock.withLock { starts } }
    var endCount: Int { lock.withLock { ends } }
}

/// The callback hands every edge to the main queue with `async`, and the monitor dispatches it with
/// another; FIFO, so two turns queued after them run after both. No clock.
@MainActor
private func drainMainQueue() async {
    for _ in 0..<2 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private let f5: CGKeyCode = 96
private let f6: CGKeyCode = 97
private let aKey: CGKeyCode = 0

/// A plain F-key press as a laptop sends it — fn held — with Caps Lock on: neither is a shortcut.
private let plainPress: CGEventFlags = [.maskSecondaryFn, .maskNonCoalesced, .maskAlphaShift]

/// Never read by the callback; `CGEventTapProxy` is non-optional.
private let unusedProxy = OpaquePointer(bitPattern: 0x1)!

/// One event through the trigger tap's callback. True when it would reach the app in front.
private func tap(
    _ context: TriggerTapContext,
    _ type: CGEventType,
    key: CGKeyCode,
    flags: CGEventFlags = [],
    isRepeat: Bool = false
) throws -> Bool {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type != .keyUp))
    event.flags = flags
    if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    let answer = HotkeyMonitor.triggerTapCallback(
        unusedProxy, type, event, Unmanaged.passUnretained(context).toOpaque()
    )
    return answer != nil
}

@MainActor
private func monitor(_ hotkey: DictationHotkey, edges: EdgeCounter) -> HotkeyMonitor {
    let monitor = HotkeyMonitor(hotkey: hotkey, currentKeyState: { _ in false })
    monitor.onPressStart = edges.start
    monitor.onPressEnd = edges.end
    return monitor
}

@MainActor
@Test("An F-key trigger's press, autorepeats and release never reach the app in front, and still dictate (F547)")
func anFKeyTriggerIsHeldBackFromTheAppInFront() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
    let context = TriggerTapContext(keyCode: f5, monitor: monitor)

    #expect(try !tap(context, .keyDown, key: f5, flags: plainPress), "the trigger's press reached the app in front")
    #expect(try !tap(context, .keyDown, key: f5, isRepeat: true), "an autorepeat reached the app in front")
    #expect(try !tap(context, .keyDown, key: f5, isRepeat: true))
    await drainMainQueue()
    #expect(edges.startCount == 1, "the held-back press started no dictation")
    #expect(try !tap(context, .keyUp, key: f5), "the release reached the app in front")
    await drainMainQueue()
    #expect(edges.endCount == 1, "the held-back release ended no dictation")
}

@MainActor
@Test("The trigger F-key with ⌘, ⌃, ⌥ or ⇧ held is a shortcut: it reaches the app and starts nothing (F547)")
func aShortcutOnTheTriggerKeyIsLetThrough() async throws {
    for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
        let edges = EdgeCounter()
        let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
        let context = TriggerTapContext(keyCode: f5, monitor: monitor)

        // ⌘F5 is VoiceOver's own on/off.
        #expect(try tap(context, .keyDown, key: f5, flags: modifier), "a shortcut on the trigger key was swallowed")
        #expect(try tap(context, .keyDown, key: f5, flags: modifier, isRepeat: true))
        #expect(try tap(context, .keyUp, key: f5, flags: modifier))
        await drainMainQueue()
        #expect(edges.startCount == 0, "a shortcut on the trigger key started a dictation")
        #expect(edges.endCount == 0)
    }
}

@MainActor
@Test("Keys other than an F-key trigger pass the trigger tap untouched and unheard (F547)")
func otherKeysPassTheTriggerTap() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
    let context = TriggerTapContext(keyCode: f5, monitor: monitor)

    #expect(try tap(context, .keyDown, key: f6))
    #expect(try tap(context, .keyUp, key: f6))
    #expect(try tap(context, .keyDown, key: aKey))
    #expect(try tap(context, .keyUp, key: aKey))
    await drainMainQueue()
    #expect(edges.startCount == 0)
    #expect(edges.endCount == 0)
}

@Test("An F-key trigger gets the tap that holds it back; a modifier or any other key keeps the listen-only one (F547)")
func onlyFKeyTriggersAreHeldBack() {
    for key in DictationKeyName.functionKeyCodes {
        #expect(HotkeyMonitor.tapKind(for: DictationHotkey(keyCode: key, mode: .hold)) == .holdsTriggerBack)
    }
    for key in DictationKeyName.modifierKeyCodes {
        #expect(HotkeyMonitor.tapKind(for: DictationHotkey(keyCode: key, mode: .toggle)) == .listenOnly)
    }
    // No Settings build offers a letter, but a stored one must not stop that letter typing anywhere.
    #expect(HotkeyMonitor.tapKind(for: DictationHotkey(keyCode: aKey, mode: .hold)) == .listenOnly)
}

/// The recovery F446 added for the listen-only tap, through the held-back tap's callback: a release
/// made while the system had disabled the tap is read from the key and dispatched — and then the
/// loss is handed to the monitor's owner, which re-arms through `start` (F547 review). Nothing on the
/// tap thread re-enables the tap.
@MainActor
@Test("A disabled trigger tap reports the release it missed, then reports its loss to be re-armed (F547, F446)")
func aDisabledTriggerTapRecoversTheMissedRelease() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
    var losses: [TriggerTapLoss] = []
    var endsWhenLost = -1
    monitor.onTriggerTapLost = { loss in
        losses.append(loss)
        endsWhenLost = edges.endCount
    }
    let context = TriggerTapContext(keyCode: f5, monitor: monitor)

    #expect(try !tap(context, .keyDown, key: f5))
    await drainMainQueue()
    try #require(edges.startCount == 1)
    // The key reads as up (`currentKeyState`), and its key-up was never delivered.
    #expect(try tap(context, .tapDisabledByTimeout, key: f5), "the disabled-tap notice must be passed on")
    await drainMainQueue()
    #expect(edges.endCount == 1, "the release made while the tap was disabled was lost")
    #expect(losses == [.timeout], "the loss never reached the owner that re-arms the trigger")
    #expect(endsWhenLost == 0, "the owner was told before the missed release was dispatched")

    #expect(try tap(context, .tapDisabledByUserInput, key: f5))
    await drainMainQueue()
    #expect(losses == [.timeout, .userInput])
}

/// The loss of a tap the monitor has since replaced says nothing about the new one.
@MainActor
@Test("A replaced trigger tap's late loss is ignored (F547)")
func aReplacedTriggerTapsLossIsIgnored() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
    var losses: [TriggerTapLoss] = []
    monitor.onTriggerTapLost = { losses.append($0) }
    let context = TriggerTapContext(keyCode: f5, monitor: monitor)
    context.isCurrent = false

    _ = try tap(context, .tapDisabledByTimeout, key: f5)
    await drainMainQueue()
    #expect(losses.isEmpty)
}

/// Re-enabling a disabled active tap from its own callback is the shape that froze the whole keyboard
/// in other apps when Accessibility was revoked under it (deskflow #9562, slovo #73). Checked as
/// source because a real disabled tap needs Accessibility to be revoked on the machine running the
/// suite; comments are stripped first (F285).
@Test("The trigger tap's callback never re-enables a tap the system disabled (F547)")
func theTriggerTapCallbackNeverReEnablesItsTap() throws {
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/Dictation/HotkeyMonitor.swift"), encoding: .utf8),
        blankStringLiterals: true
    )
    let marker = try #require(source.range(of: "static let triggerTapCallback"))
    let openBrace = try #require(source.range(of: "{", range: marker.upperBound..<source.endIndex))
    var depth = 1
    var cursor = openBrace.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    let callback = source[openBrace.upperBound..<cursor]
    #expect(callback.contains("tapDisabledByTimeout"), "the callback no longer handles a disabled tap at all")
    #expect(!callback.contains("tapEnable("), "the callback re-enables the active tap the system disabled")
}

/// A tap replaced since it heard the key can still have a forwarded press on the main queue.
@MainActor
@Test("A press forwarded by the tap of a replaced F-key trigger starts nothing (F547)")
func aForwardedPressOfAReplacedTriggerStartsNothing() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f6, mode: .hold), edges: edges)
    let staleContext = TriggerTapContext(keyCode: f5, monitor: monitor)

    _ = try tap(staleContext, .keyDown, key: f5)
    await drainMainQueue()
    #expect(edges.startCount == 0)
}

// MARK: - Armed listen-only for want of Accessibility

/// A monitor whose next `start` succeeds, holding the F-key back or not as the test says.
private final class FallbackReportingMonitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?
    /// What the next `start` arms: listen-only (Accessibility missing) or holding back.
    var nextStartHoldsBack = false
    private(set) var isArmedWithoutHoldingBack = false
    private(set) var startCount = 0

    func start(hotkey: DictationHotkey) -> Bool {
        startCount += 1
        isArmedWithoutHoldingBack = !nextStartHoldsBack
        return true
    }
    func stop() { isArmedWithoutHoldingBack = false }
    func resetToggleState() {}
}

/// F547 × F523. With Input Monitoring granted and Accessibility not, the F-key trigger's active tap
/// is refused and the listen-only one works, so the arm "succeeds" and F523's retry — which waits
/// for a failed arm — never ran again: granting Accessibility afterwards left the key reaching the
/// app in front until the next toggle, key change or relaunch.
@MainActor
@Test("An F-key armed listen-only for want of Accessibility is re-armed to hold back when WhisperMeet comes to the front (F547)")
func aListenOnlyFKeyIsRearmedOnActivation() throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HotkeyTriggerHoldBackTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(try JSONEncoder().encode(DictationHotkey(keyCode: f5, mode: .hold)), forKey: "dictationHotkey")
    let monitor = FallbackReportingMonitor()
    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
    recorder.stopDuration = 0.1 // a tap, discarded, so the dictation below ends idle
    let notifications = NotificationCenter()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activationNotifications: notifications,
        activateOnInit: true
    )
    try #require(monitor.startCount == 1)
    try #require(controller.status == .idle, "a listen-only arm still works, and says so")

    // A dictation is live: coming to the front must not rebuild the tap under it (F446).
    monitor.onPressStart?()
    try #require(controller.status == .listening)
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == 1, "the trigger was re-armed under a live dictation")
    monitor.onPressEnd?()

    // Accessibility granted; the user comes back to WhisperMeet with dictation idle.
    try #require(!controller.isActive)
    monitor.nextStartHoldsBack = true
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == 2, "the listen-only trigger was never re-armed")
    #expect(!monitor.isArmedWithoutHoldingBack)

    // Holding back now: later activations leave it alone.
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.startCount == 2)
}
