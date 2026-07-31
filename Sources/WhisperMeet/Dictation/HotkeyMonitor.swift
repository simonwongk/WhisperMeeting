import AppKit
import ApplicationServices
import CoreGraphics
import WhisperCore

/// Injection seam so `DictationController`'s hotkey-driven state machine is testable without a real
/// CGEventTap (which requires Accessibility). `HotkeyMonitor` is the only production conformer.
protocol HotkeyMonitoring: AnyObject {
    var onPressStart: (() -> Void)? { get set }
    var onPressEnd: (() -> Void)? { get set }
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

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkey: DictationHotkey = .rightOption
    private var keyDown = false       // physical down-state of the configured hotkey key
    private var toggledOn = false     // (toggle mode) whether dictation is currently on
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
        stop()
        self.hotkey = hotkey
        keyDown = false
        toggledOn = false
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
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        keyDown = false
        toggledOn = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else { return }

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
        dispatch(pressed: nowDown)
    }

    func recoverFromDisabledTap() {
        keyDown = currentKeyState(CGKeyCode(hotkey.keyCode))
    }

    func resetToggleState() {
        toggledOn = false
    }

    /// Whether the configured modifier hotkey key is currently physically down, read from the
    /// device-dependent modifier bits in the event flags (which encode left vs right separately).
    private func modifierIsDown(_ event: CGEvent) -> Bool {
        let deviceMask: UInt64
        switch hotkey.keyCode {
        case 58: deviceMask = 0x0000_0020 // left Option
        case 61: deviceMask = 0x0000_0040 // right Option
        case 59: deviceMask = 0x0000_0001 // left Control
        case 62: deviceMask = 0x0000_2000 // right Control
        case 56: deviceMask = 0x0000_0002 // left Shift
        case 60: deviceMask = 0x0000_0004 // right Shift
        case 55: deviceMask = 0x0000_0008 // left Command
        case 54: deviceMask = 0x0000_0010 // right Command
        default: deviceMask = 0
        }
        return (event.flags.rawValue & deviceMask) != 0
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
