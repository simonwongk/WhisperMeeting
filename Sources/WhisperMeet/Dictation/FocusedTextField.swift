// Sources/WhisperMeet/Dictation/FocusedTextField.swift
import AppKit
import ApplicationServices

/// Whether the app the dictation is about to be pasted into has a text field focused (F516).
///
/// It decides one thing only: whether the paste's borrowed clipboard is given back. A dictation
/// that went into a text field restores the user's clipboard; one that went nowhere is left on it,
/// where the user will look for it. It never decides whether to paste — an app can hide its field
/// from Accessibility, and a paste into nothing is harmless, so the paste always happens.
enum FocusedTextField {
    struct Probe: Equatable {
        let isTextField: Bool
        /// App and role, for the diagnostic log only ("com.apple.TextEdit AXTextArea").
        let summary: String
    }

    /// The standard text roles, plus anything exposing a text selection — which is how a web or
    /// Electron editor (a contenteditable) presents itself once its accessibility tree exists.
    static func probe() -> Probe {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.bundleIdentifier ?? "unknown app"
        guard let focused = focusedElement(in: app) else {
            return Probe(isTextField: false, summary: "\(name): no focused element visible")
        }
        let role = string(focused, kAXRoleAttribute) ?? "no role"
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        var selection: AnyObject?
        let hasSelection = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &selection
        ) == .success
        return Probe(isTextField: textRoles.contains(role) || hasSelection, summary: "\(name) \(role)")
    }

    private static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // A hung app must not hold up the paste: Accessibility's default wait is six seconds.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if let element = element(systemWide, kAXFocusedUIElementAttribute) { return element }
        guard let app else { return nil }
        // Chromium and Electron build their accessibility tree only for a client that asks for it
        // (`AXManualAccessibility`, Chromium's documented switch). Ignored by every other app.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return element(appElement, kAXFocusedUIElementAttribute)
    }

    private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ source: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
