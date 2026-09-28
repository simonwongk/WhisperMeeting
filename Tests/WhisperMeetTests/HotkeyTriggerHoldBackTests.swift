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
/// made while the system had disabled the tap is read from the key and dispatched.
@MainActor
@Test("A disabled trigger tap reports the release it missed when it recovers (F547, F446)")
func aDisabledTriggerTapRecoversTheMissedRelease() async throws {
    let edges = EdgeCounter()
    let monitor = monitor(DictationHotkey(keyCode: f5, mode: .hold), edges: edges)
    let context = TriggerTapContext(keyCode: f5, monitor: monitor)

    #expect(try !tap(context, .keyDown, key: f5))
    await drainMainQueue()
    try #require(edges.startCount == 1)
    // The key reads as up (`currentKeyState`), and its key-up was never delivered.
    #expect(try tap(context, .tapDisabledByTimeout, key: f5), "the disabled-tap notice must be passed on")
    await drainMainQueue()
    #expect(edges.endCount == 1, "the release made while the tap was disabled was lost")
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
