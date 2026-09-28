import AppKit
import ApplicationServices
import CoreGraphics
import WhisperCore
import os

/// Injection seam so `DictationController`'s hotkey-driven state machine is testable without a real
/// CGEventTap (which requires Accessibility). `HotkeyMonitor` is the only production conformer.
protocol HotkeyMonitoring: AnyObject {
    var onPressStart: (() -> Void)? { get set }
    var onPressEnd: (() -> Void)? { get set }
    /// The press that started a dictation turned out to be part of a shortcut (F448).
    var onPressCancel: (() -> Void)? { get set }
    @discardableResult func start(hotkey: DictationHotkey) -> Bool
    func stop()
    /// Clear toggle mode's latched on-state so the next press is treated as a fresh start. The
    /// controller calls this whenever it refuses a start, so a refused toggle press cannot leave the
    /// monitor believing dictation is "on" and invert the on/off edges (F38).
    func resetToggleState()
}

/// Global push-to-talk listener backed by a CGEventTap. Detects the configured key's down/up
/// (modifier keys via `.flagsChanged`, regular keys via `.keyDown`/`.keyUp`) and reports
/// press/release on the main queue. Requires Accessibility (the tap) — the same grant used for paste.
///
/// Two kinds of tap (F547). A modifier trigger gets a listen-only tap on the main run loop: the
/// modifier still reaches the app in front, where it is half of every shortcut. An F-key trigger
/// gets an active tap that holds the key back from the app in front while dictation is armed —
/// under the listen-only tap an F-key held to talk in Terminal typed an escape sequence per
/// autorepeat, and F6/F7 stepped Xcode's debugger. That tap runs on its own thread
/// (`TriggerTapThread`): an active tap holds every key event in the session until its callback
/// answers, and on the main run loop a busy main thread would have stalled typing in every app.
final class HotkeyMonitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Clicks, for F448's chord check only, and deliberately a tap of its own. CGEvent.h: when a tap
    /// may not see key events "the appropriate bits in the mask are cleared", and NULL comes back
    /// only if that empties the mask. Mouse bits in the key tap's mask could therefore let
    /// `tapCreate` succeed without Accessibility, and a dead trigger would report itself as working.
    private var clickTap: CFMachPort?
    private var clickRunLoopSource: CFRunLoopSource?
    /// An F-key trigger's active tap (F547), serviced on `TriggerTapThread`. The context is retained
    /// for the tap and released on that thread once the tap is gone, so a callback already running
    /// there never reads a freed one.
    private var triggerTap: (port: CFMachPort, source: CFRunLoopSource, context: Unmanaged<TriggerTapContext>)?
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation")
    private var hotkey: DictationHotkey = .rightOption
    private var keyDown = false       // physical down-state of the configured hotkey key
    private var toggledOn = false     // (toggle mode) whether dictation is currently on
    /// Whether this hold of a modifier trigger can no longer cancel a dictation: it already has, so
    /// ⌘-Tab-Tab-Tab reports one cancel, not three — or it was already down, and not by a press this
    /// monitor took as the trigger's, when adopted (F584).
    private var cancelledThisHold = false
    /// Counts toggle presses, so a dropped start can tell whether the on-state is still its own.
    private var togglePresses = 0
    private let currentKeyState: (CGKeyCode) -> Bool

    init(
        hotkey: DictationHotkey = .rightOption,
        currentKeyState: @escaping (CGKeyCode) -> Bool = {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }
    ) {
        self.hotkey = hotkey
        self.currentKeyState = currentKeyState
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    deinit { stop() }

    /// Which tap a trigger gets (F547). An F-key is held back from the app in front; anything else
    /// is only listened to. Only F-keys: a stored trigger that is some other key (no build's Settings
    /// offers one) would otherwise stop typing that key in every app.
    enum TapKind: Equatable {
        case listenOnly
        case holdsTriggerBack
    }

    static func tapKind(for hotkey: DictationHotkey) -> TapKind {
        DictationKeyName.functionKeyCodes.contains(hotkey.keyCode) ? .holdsTriggerBack : .listenOnly
    }

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool {
        removeTap()
        adopt(hotkey)
        if Self.tapKind(for: hotkey) == .holdsTriggerBack {
            if startTriggerTap(keyCode: hotkey.keyCode) { return true }
            // Without it the trigger still works, listen-only as before F547; it just also reaches
            // the app in front. Never a dead key because the better tap was refused.
            log.error("the F-key trigger's active tap could not be created; listening only")
        }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
            // The OS disables a tap on timeout / heavy input; re-enable so the always-on hotkey survives.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                monitor.recoverFromDisabledTap()
                return Unmanaged.passUnretained(event)
            }
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false // not trusted / Input Monitoring off
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if Self.modifierDeviceMask(for: hotkey.keyCode) != 0 { startClickTap() }
        return true
    }

    /// Best effort: without it a click during the hold is not seen as a chord, and nothing else changes.
    private func startClickTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.clickTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        clickTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        clickRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The F-key trigger's active tap, on `TriggerTapThread` (F547). Only key-down and key-up: an
    /// F-key trigger needs neither modifier changes nor clicks (F448's chord cancel is for modifier
    /// triggers). Per CGEvent.h, a tap not permitted to see key events has those bits cleared, and an
    /// empty mask returns NULL, so a missing grant fails here rather than making a deaf tap.
    private func startTriggerTap(keyCode: UInt16) -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passRetained(TriggerTapContext(keyCode: keyCode, monitor: self))
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.triggerTapCallback,
            userInfo: context.toOpaque()
        ) else {
            context.release() // no tap, so no callback can hold it
            return false
        }
        // Set before the source is added: the tap thread reads it only from callbacks, which cannot
        // run before then.
        context.takeUnretainedValue().port = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            context.release() // never added to a run loop, so no callback can hold it
            return false
        }
        let loop = TriggerTapThread.runLoop
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(loop)
        triggerTap = (port, source, context)
        return true
    }

    /// The F-key trigger's tap callback (F547), on `TriggerTapThread`. It must stay trivially cheap:
    /// every key event in the session waits on its answer. It reads two integer fields and the
    /// flags, updates `TriggerKeyFilter` (a few comparisons, no lock), and hands the monitor an edge
    /// with at most one `DispatchQueue.main.async`, only for the trigger key; it never waits on the
    /// main thread. Returning nil deletes the event (CGEventTypes.h, `CGEventTapCallBack`).
    /// Internal so a test can call it with a real `CGEvent` and no tap.
    static let triggerTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<TriggerTapContext>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disabled the tap, so the key reached the app meanwhile, and an edge may
            // have gone unheard. Re-enable, and let the monitor read the key as F446 does.
            if let port = context.port { CGEvent.tapEnable(tap: port, enable: true) }
            DispatchQueue.main.async { context.monitor?.recoverFromDisabledTap() }
            return Unmanaged.passUnretained(event)
        }
        let verdict = context.filter.verdict(
            type: type,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        if verdict.forward {
            let keyCode = context.filter.keyCode
            let down = type == .keyDown
            DispatchQueue.main.async { context.monitor?.handleTriggerKey(keyCode, down: down) }
        }
        return verdict.consume ? nil : Unmanaged.passUnretained(event)
    }

    /// An F-key trigger's press or release, as its tap forwarded it (F547). A tap replaced since it
    /// heard the key can still have one on the way; a key that is no longer the trigger is ignored,
    /// as `handle` ignores it.
    func handleTriggerKey(_ keyCode: UInt16, down: Bool) {
        guard keyCode == hotkey.keyCode else { return }
        handleKeyStateChange(down)
    }

    func stop() {
        removeTap()
        keyDown = false
        toggledOn = false
    }

    private func removeTap() {
        if let triggerTap {
            let loop = TriggerTapThread.runLoop
            CFRunLoopRemoveSource(loop, triggerTap.source, .commonModes)
            CGEvent.tapEnable(tap: triggerTap.port, enable: false)
            CFMachPortInvalidate(triggerTap.port)
            // After a callback that may be running now: the tap thread runs one thing at a time.
            let context = triggerTap.context
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { context.release() }
            CFRunLoopWakeUp(loop)
            self.triggerTap = nil
        }
        for (source, port) in [(runLoopSource, tap), (clickRunLoopSource, clickTap)] {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
        }
        tap = nil
        runLoopSource = nil
        clickTap = nil
        clickRunLoopSource = nil
    }

    /// The edge state `start` begins from (F446). Internal so a test can drive it without creating a
    /// real event tap, which needs Accessibility and would hear the keyboard of whoever runs the
    /// suite.
    ///
    /// Nothing here is assumed. The key's state is read, not reset to "up": Settings' "Change" sets a
    /// trigger on that key's own key-down, so the key is usually held when it is adopted, and a held
    /// key can repeat its key-down. Read as up, the first repeat is a press nobody made: in toggle
    /// mode it turns off the dictation the old key turned on, and in hold mode it is a start. The
    /// read also keeps a release when the key is still held at the re-arm: when Change re-arms the
    /// same key while its press is still on the way to the controller, a reset made that key's
    /// release look like a duplicate "up", dropped with the microphone on (F446). A release made
    /// before the re-arm, while the old tap was being replaced, went with that tap: the key reads as
    /// up. If this monitor heard the press, that release is dispatched here, as
    /// `recoverFromDisabledTap` dispatches an edge the tap missed (F636); only resynchronising let the
    /// start still queued open a hold capture that nothing but the watchdog closed. Toggle mode
    /// ignores the release as it always does.
    ///
    /// A key already down whose press this monitor did not take as the trigger's started no
    /// dictation, so it must not cancel one (F584): with Left ⌘ chosen while a toggle dictation is on,
    /// ⌘-Tab was F448's shortcut cancel and dropped that dictation unheard. Its next press is a fresh
    /// hold and can cancel again.
    ///
    /// Toggle mode's on-state belongs to the dictation, not to the key: switching to another toggle
    /// key while dictation is on leaves it on, so the new key's next press turns it off. Only a
    /// change of mode clears it, since it means nothing in hold mode. (`stop()` still clears
    /// everything: nothing can be in flight once dictation is off.)
    func adopt(_ newHotkey: DictationHotkey) {
        let heardItsPress = keyDown && newHotkey.keyCode == hotkey.keyCode
        if newHotkey.mode != hotkey.mode { toggledOn = false }
        hotkey = newHotkey
        let isDown = currentKeyState(CGKeyCode(newHotkey.keyCode))
        if heardItsPress, !isDown {
            handleKeyStateChange(false)
        } else {
            keyDown = isDown
        }
        if !heardItsPress { cancelledThisHold = keyDown }
    }

    /// One tapped event. Internal so a test can feed it real `CGEvent`s without a live tap.
    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Read before the key code: a mouse event's key-code field is 0, which is the A key.
            noteChordInput()
            return
        default:
            break
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else {
            if type == .keyDown { noteChordInput() }
            return
        }

        let nowDown: Bool
        switch type {
        case .flagsChanged:
            // Absolute, per-side read: the device-dependent modifier bit reflects THIS specific key's
            // true current state (unlike the side-agnostic .maskAlternate etc.), so `keyDown` cannot
            // desync the way a relative toggle would.
            nowDown = modifierIsDown(event)
        case .keyDown:
            nowDown = true
        case .keyUp:
            nowDown = false
        default:
            return
        }
        handleKeyStateChange(nowDown)
    }

    func handleKeyStateChange(_ nowDown: Bool) {
        guard nowDown != keyDown else { return } // ignore autorepeat / duplicate transitions
        keyDown = nowDown
        if nowDown { cancelledThisHold = false }
        dispatch(pressed: nowDown)
    }

    /// Another key went down, or the mouse was clicked (F448). While a MODIFIER trigger is held
    /// that makes the press half of a shortcut — ⌘-Tab, ⌥-click, ⌥⇧→, a character typed with Right
    /// ⌥ — not a dictation, so the press is cancelled: the controller drops the capture unheard.
    /// Only a modifier: an F-key forms no shortcuts, and a key typed while nothing is held is typing.
    /// A plain press and release of the trigger with nothing in between is still a dictation.
    private func noteChordInput() {
        guard keyDown, !cancelledThisHold, Self.modifierDeviceMask(for: hotkey.keyCode) != 0 else { return }
        cancelledThisHold = true
        DispatchQueue.main.async { self.onPressCancel?() }
    }

    /// The tap was disabled for a while, so an edge may have happened unseen. Read the key and
    /// dispatch whatever changed (F446): only resynchronising `keyDown` corrected the state and
    /// swallowed the edge, so a hold-mode release made during the gap left the capture running to
    /// the 120 s watchdog, which then pasted it. A press and a release that both fall inside the gap
    /// leave nothing in the live state, so they cannot be recovered.
    func recoverFromDisabledTap() {
        handleKeyStateChange(currentKeyState(CGKeyCode(hotkey.keyCode)))
    }

    func resetToggleState() {
        toggledOn = false
    }

    /// Whether the configured modifier hotkey key is currently physically down, read from the
    /// device-dependent modifier bits in the event flags (which encode left vs right separately).
    private func modifierIsDown(_ event: CGEvent) -> Bool {
        (event.flags.rawValue & Self.modifierDeviceMask(for: hotkey.keyCode)) != 0
    }

    /// The device-dependent flag bit for one side's modifier key; 0 for a key that is no modifier.
    /// One table, shared with Settings' trigger capture (F521).
    private static func modifierDeviceMask(for keyCode: UInt16) -> UInt64 {
        DictationKeyName.modifierDeviceMask(for: keyCode)
    }

    /// A start is delivered only if the trigger it was heard for is still the trigger, compared by
    /// value (F584). An edge reaches the controller one main-queue turn after the tap heard it, and
    /// the controller can arm another trigger in between. A start delivered after that began a
    /// dictation nobody pressed the new trigger for. Under hold, its own release came from a key the
    /// monitor no longer hears, so it ran until the new key's next release delivered it; under a
    /// toggle whose on-state the change of mode had cleared, every press was a refused start and
    /// only the watchdog ended it.
    ///
    /// An end is always delivered: it ends a dictation the old key started, which is what it was
    /// pressed for, and a dropped toggle end would leave the dictation on with its on-state already
    /// off. A dropped toggle start undoes the on-state its press set, unless a later press has
    /// toggled it since: that press's edge is queued behind this one, and the on-state is its.
    private func dispatch(pressed: Bool) {
        let heardFor = hotkey
        switch hotkey.mode {
        case .hold:
            DispatchQueue.main.async {
                guard pressed else { self.onPressEnd?(); return }
                guard self.hotkey == heardFor else { return }
                self.onPressStart?()
            }
        case .toggle:
            guard pressed else { return } // act on the down edge only
            toggledOn.toggle()
            togglePresses &+= 1
            let starting = toggledOn
            let press = togglePresses
            DispatchQueue.main.async {
                guard starting else { self.onPressEnd?(); return }
                guard self.hotkey == heardFor else {
                    if self.togglePresses == press { self.toggledOn = false }
                    return
                }
                self.onPressStart?()
            }
        }
    }
}

/// What an F-key trigger's tap does with one event (F547): whether the app in front gets it, and
/// whether the monitor hears it. Owned by the tap thread.
///
/// A press of the trigger alone is held back, and so are its autorepeats and its release, so the app
/// in front sees none of that press. A press with ⌘ ⌃ ⌥ or ⇧ held is a shortcut that belongs to
/// someone else — ⌘F5 turns VoiceOver on and off — so it is let through whole, and it starts no
/// dictation: the two uses of the key never overlap. A release is always heard, since an end is
/// always safe (F584). Every other key passes untouched and unheard.
struct TriggerKeyFilter: Equatable {
    let keyCode: UInt16
    /// Whether the current press of the trigger is being held back.
    private(set) var holdingBack = false

    struct Verdict: Equatable {
        /// Keep the event from the app in front.
        var consume: Bool
        /// Hand the monitor this press or release.
        var forward: Bool
    }

    static let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    mutating func verdict(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Verdict {
        guard keyCode == self.keyCode else { return Verdict(consume: false, forward: false) }
        switch type {
        case .keyDown:
            if !isRepeat { holdingBack = flags.intersection(Self.shortcutFlags).isEmpty }
            return Verdict(consume: holdingBack, forward: holdingBack && !isRepeat)
        case .keyUp:
            defer { holdingBack = false }
            return Verdict(consume: holdingBack, forward: true)
        default:
            return Verdict(consume: false, forward: false)
        }
    }
}

/// What an F-key trigger's tap knows (F547). `filter` is read and written only by the tap's
/// callback, on the tap thread; `monitor` is read only on the main queue; `port` is written once on
/// the main thread before the tap's source is added, and read by the callback after.
final class TriggerTapContext: @unchecked Sendable {
    var filter: TriggerKeyFilter
    var port: CFMachPort?
    weak var monitor: HotkeyMonitor?

    init(keyCode: UInt16, monitor: HotkeyMonitor?) {
        filter = TriggerKeyFilter(keyCode: keyCode)
        self.monitor = monitor
    }
}

/// The thread an F-key trigger's active tap is serviced on (F547), started the first time one is
/// created and kept for the life of the process. It does nothing else, so the tap's answer never
/// waits behind the main thread's work.
enum TriggerTapThread {
    private final class Handoff: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop?
    }

    static let runLoop: CFRunLoop = {
        let handoff = Handoff()
        let thread = Thread {
            handoff.runLoop = CFRunLoopGetCurrent()
            // `run()` returns at once from a run loop with nothing in it; a port nobody signals keeps
            // this one waiting for taps.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            handoff.ready.signal()
            RunLoop.current.run()
        }
        thread.name = "WhisperMeet dictation trigger tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        handoff.ready.wait()
        return handoff.runLoop!
    }()
}
