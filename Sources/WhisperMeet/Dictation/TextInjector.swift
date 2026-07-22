// Sources/WhisperMeet/Dictation/TextInjector.swift
import AppKit
import ApplicationServices
import CoreGraphics

/// Delivers dictated text: writes it to the clipboard and, when Accessibility is granted,
/// synthesizes ⌘V into the focused app. Otherwise leaves it on the clipboard for a manual paste.
enum TextInjector {
    enum Delivery { case pasted, clipboard }

    @discardableResult
    static func deliver(_ text: String) -> Delivery {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return .clipboard
        }

        // Let the pasteboard settle before the synthetic paste.
        usleep(20_000)

        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        return .pasted
    }
}
