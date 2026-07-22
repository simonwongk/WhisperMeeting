// Sources/WhisperMeet/Dictation/HotkeyMonitor.swift
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
    private var isKeyDown = false

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool {
        stop()
        self.hotkey = hotkey
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
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
        }
        tap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    private var flagMask: CGEventFlags {
        switch hotkey.keyCode {
        case 61, 58: return .maskAlternate   // right/left Option
        case 59, 62: return .maskControl     // left/right Control
        case 55, 54: return .maskCommand     // left/right Command
        case 56, 60: return .maskShift       // left/right Shift
        default: return .maskAlternate
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else { return }

        let pressed: Bool
        switch type {
        case .flagsChanged: pressed = event.flags.contains(flagMask)
        case .keyDown: pressed = true
        case .keyUp: pressed = false
        default: return
        }
        dispatch(pressed: pressed)
    }

    private func dispatch(pressed: Bool) {
        switch hotkey.mode {
        case .hold:
            if pressed, !isKeyDown {
                isKeyDown = true
                DispatchQueue.main.async { self.onPressStart?() }
            } else if !pressed, isKeyDown {
                isKeyDown = false
                DispatchQueue.main.async { self.onPressEnd?() }
            }
        case .toggle:
            guard pressed else { return } // act on key-down edge only
            isKeyDown.toggle()
            let starting = isKeyDown
            DispatchQueue.main.async {
                starting ? self.onPressStart?() : self.onPressEnd?()
            }
        }
    }
}
