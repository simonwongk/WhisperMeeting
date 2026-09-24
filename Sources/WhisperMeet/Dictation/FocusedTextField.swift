// Sources/WhisperMeet/Dictation/FocusedTextField.swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What has focus where a dictation is about to be pasted: taken when the key is pressed and again
/// at delivery.
///
/// `isTextField` (F516) decides one thing only: whether the paste's borrowed clipboard is given
/// back. A dictation that went into a text field restores the user's clipboard; one that went
/// nowhere is left on it, where the user will look for it. It never decides whether to paste — an
/// app can hide its field from Accessibility, and a paste into nothing is harmless.
///
/// The app and the secure-input state (F445) do decide whether to paste, because pasting into a
/// different app than the one the key was pressed in, or into a password field, is not harmless.
enum FocusedTextField {
    struct Probe: Equatable {
        let isTextField: Bool
        /// App and role, for the diagnostic log only ("com.apple.TextEdit AXTextArea").
        let summary: String
        /// The frontmost app's process (F445), nil when there is none.
        var processIdentifier: pid_t? = nil
        /// A password field has focus, or some process has secure keyboard entry on (F445).
        var isSecure = false
    }

    /// The standard text roles, plus anything exposing a text selection — which is how a web or
    /// Electron editor (a contenteditable) presents itself once its accessibility tree exists.
    ///
    /// Secure (F445) is either signal, because each misses cases the other sees: the focused
    /// element's `AXSecureTextField` subrole, which native, WebKit and Chromium password fields
    /// report but an app hiding its tree does not; and `IsSecureEventInputEnabled()`, which a
    /// password field turns on however it is drawn — and which any process can leave on (Terminal's
    /// Secure Keyboard Entry). A false positive costs a paste — the text is still on the clipboard —
    /// where a false negative types someone's words into a password prompt.
    static func probe() -> Probe {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.bundleIdentifier ?? "unknown app"
        let pid = app?.processIdentifier
        let secureEntry = IsSecureEventInputEnabled()
        guard let focused = focusedElement(in: app) else {
            return Probe(
                isTextField: false, summary: "\(name): no focused element visible",
                processIdentifier: pid, isSecure: secureEntry
            )
        }
        let role = string(focused, kAXRoleAttribute) ?? "no role"
        let isPasswordField = string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        var selection: AnyObject?
        let hasSelection = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &selection
        ) == .success
        return Probe(
            isTextField: textRoles.contains(role) || hasSelection, summary: "\(name) \(role)",
            processIdentifier: pid, isSecure: secureEntry || isPasswordField
        )
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
