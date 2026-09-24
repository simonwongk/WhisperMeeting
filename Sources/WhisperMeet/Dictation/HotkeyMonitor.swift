import AppKit
import ApplicationServices
import CoreGraphics
import WhisperCore

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

/// Global push-to-talk listener backed by a listen-only CGEventTap. Detects the configured key's
/// down/up (modifier keys via `.flagsChanged`, regular keys via `.keyDown`/`.keyUp`) and reports
/// press/release on the main queue. Requires Accessibility (the tap) — the same grant used for paste.
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
    private var hotkey: DictationHotkey = .rightOption
    private var keyDown = false       // physical down-state of the configured hotkey key
    private var toggledOn = false     // (toggle mode) whether dictation is currently on
    /// Whether this hold of a modifier trigger has already been cancelled as part of a shortcut, so
    /// ⌘-Tab-Tab-Tab reports one cancel, not three.
    private var cancelledThisHold = false
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

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool {
        removeTap()
        adopt(hotkey)
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

    func stop() {
        removeTap()
        keyDown = false
        toggledOn = false
    }

    private func removeTap() {
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
    /// Nothing here is assumed. The key's state is read, not reset to "up": Settings' "Change" hears
    /// the trigger itself, so the tap is routinely rebuilt while the key that started a dictation is
    /// still held, and a reset made that key's release look like a duplicate "up" — dropped, with the
    /// microphone on. And toggle mode's on-state belongs to the dictation, not to the key: switching
    /// to another toggle key while dictation is on leaves it on, so the new key's next press turns it
    /// off. Only a change of mode clears it, since it means nothing in hold mode. (`stop()` still
    /// clears everything: nothing can be in flight once dictation is off.)
    func adopt(_ newHotkey: DictationHotkey) {
        if newHotkey.mode != hotkey.mode { toggledOn = false }
        hotkey = newHotkey
        keyDown = currentKeyState(CGKeyCode(newHotkey.keyCode))
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
    private static func modifierDeviceMask(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 58: 0x0000_0020 // left Option
        case 61: 0x0000_0040 // right Option
        case 59: 0x0000_0001 // left Control
        case 62: 0x0000_2000 // right Control
        case 56: 0x0000_0002 // left Shift
        case 60: 0x0000_0004 // right Shift
        case 55: 0x0000_0008 // left Command
        case 54: 0x0000_0010 // right Command
        default: 0
        }
    }

    private func dispatch(pressed: Bool) {
        switch hotkey.mode {
        case .hold:
            DispatchQueue.main.async {
                pressed ? self.onPressStart?() : self.onPressEnd?()
            }
        case .toggle:
            guard pressed else { return } // act on the down edge only
            toggledOn.toggle()
            let starting = toggledOn
            DispatchQueue.main.async {
                starting ? self.onPressStart?() : self.onPressEnd?()
            }
        }
    }
}
