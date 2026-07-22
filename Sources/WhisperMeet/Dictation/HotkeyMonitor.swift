import AppKit
import ApplicationServices
import CoreGraphics
import WhisperCore

/// Global push-to-talk listener backed by a listen-only CGEventTap. Detects the configured key's
/// down/up (modifier keys via `.flagsChanged`, regular keys via `.keyDown`/`.keyUp`) and reports
/// press/release on the main queue. Requires Accessibility (the tap) — the same grant used for paste.
final class HotkeyMonitor {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkey: DictationHotkey = .rightOption
    private var keyDown = false       // physical down-state of the configured hotkey key
    private var toggledOn = false     // (toggle mode) whether dictation is currently on

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
            // A flagsChanged carrying our keyCode is a transition of THAT specific key. Its direction
            // can't be read reliably from the side-agnostic modifier mask when another same-type
            // modifier is held, so track this key's own state by toggling on each matching event.
            nowDown = !keyDown
        case .keyDown:
            nowDown = true
        case .keyUp:
            nowDown = false
        default:
            return
        }
        guard nowDown != keyDown else { return } // ignore autorepeat / duplicate transitions
        keyDown = nowDown
        dispatch(pressed: nowDown)
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
