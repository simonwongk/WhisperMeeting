// Sources/WhisperMeet/Dictation/FocusedTextField.swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// What has focus where a dictation is about to be pasted: taken when the key is pressed and again
/// at delivery.
///
/// `isTextField` (F516) decides whether the paste's borrowed clipboard is given back. A dictation
/// that went into a text field restores the user's clipboard; one that may have gone nowhere is
/// left on it, where the user will look for it, and the pill says "Pasted — also on the clipboard"
/// instead of "Pasted" (F600). Either way the delivery is a paste — history `.pasted`, no "press ⌘V"
/// notice — because the ⌘V was sent. It does not decide whether to paste — an app can hide its
/// field from Accessibility, and a paste into nothing is harmless — except as evidence about secure
/// input: a focused ordinary text field is what lets a paste through while another app holds secure
/// keyboard entry (F585).
///
/// The app and the secure-input state (F445) do decide whether to paste, because pasting into a
/// different app than the one the key was pressed in, or into a password field, is not harmless.
enum FocusedTextField {
    /// Why a dictation must not be pasted where the probe looked (F445, F585).
    enum SecureInput: Equatable {
        /// The focused element is a password field: its subrole is `AXSecureTextField`.
        case passwordField
        /// Secure event input is on and nothing showed it was safe to paste. `app` is the app the
        /// window server names for it, when it names one — the app in front when secure input came
        /// on, not necessarily the one that turned it on (see `secureInputProcess()`).
        case keyboardEntry(app: String?)
    }

    struct Probe: Equatable {
        let isTextField: Bool
        /// App and role, and the secure-input reading when it is on, for the diagnostic log only
        /// ("com.apple.TextEdit AXTextArea; secure input on, session names pid 412").
        let summary: String
        /// The frontmost app's process (F445), nil when there is none.
        var processIdentifier: pid_t? = nil
        /// Why pasting here is not safe, or nil when it is (F445, F585).
        var secureInput: SecureInput? = nil

        var isSecure: Bool { secureInput != nil }
    }

    /// Everything `probe()` reads from the system, before any judgement is made about it: the seam
    /// the judgement is tested through, since the reads themselves need a real focused app.
    struct Reading: Equatable {
        struct Element: Equatable {
            var role: String?
            var subrole: String?
            /// The element answers `kAXSelectedTextRangeAttribute`.
            var hasSelectedTextRange = false
            /// `AXUIElementIsAttributeSettable` for `kAXValueAttribute` and
            /// `kAXSelectedTextAttribute`; nil when the call failed or the attribute is not
            /// supported, which says nothing either way (F601).
            var valueSettable: Bool? = nil
            var selectedTextSettable: Bool? = nil
        }

        /// The frontmost app.
        var bundleIdentifier: String?
        var processIdentifier: pid_t?
        /// The focused element, nil when Accessibility shows none.
        var focused: Element?
        /// `IsSecureEventInputEnabled()`: some process, any process, has secure event input on.
        var secureEventInput = false
        /// The process the window-server session dictionary names under
        /// `kCGSSessionSecureInputPID`, and that process's name — see `secureInputProcess()`.
        var secureInputProcessIdentifier: pid_t?
        var secureInputAppName: String?
    }

    static func probe() -> Probe {
        probe(reading: read())
    }

    /// A text field is one of the standard text roles, or anything exposing a text selection —
    /// which is how a web or Electron editor (a contenteditable) presents itself once its
    /// accessibility tree exists.
    ///
    /// Read-only (F601) is read but, for now, only logged: an element for which
    /// `AXUIElementIsAttributeSettable` says "no" for both the value and the selected text is marked
    /// "(read-only)" in the summary and still counts as a text field. A read-only console or log
    /// pane answers that way, and acting on it would stop its clipboard being restored over the
    /// transcript. But the lane J review found Ghostty's terminal view implements only the getters
    /// for both attributes and iTerm2's only a selection-range setter, and showed in-process that
    /// AppKit reports a getters-only view as settable for neither — so these two answers cannot
    /// tell a terminal from a log pane. The two mistakes are not equal: a read-only pane taken for a
    /// field loses the transcript from the clipboard, where it is still in the history; a terminal
    /// taken for a read-only pane loses the user's own clipboard, which is nowhere else. Until the
    /// on-screen check (F174) records what Terminal, iTerm2 and Ghostty really answer, the reading
    /// decides nothing.
    static func probe(reading: Reading) -> Probe {
        let name = reading.bundleIdentifier ?? "unknown app"
        var summary = "\(name): no focused element visible"
        var isTextField = false
        var isPasswordField = false
        if let focused = reading.focused {
            let role = focused.role ?? "no role"
            let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
            let isReadOnly = focused.valueSettable == false && focused.selectedTextSettable == false
            summary = "\(name) \(role)\(isReadOnly ? " (read-only)" : "")"
            isTextField = textRoles.contains(role) || focused.hasSelectedTextRange
            isPasswordField = focused.subrole == kAXSecureTextFieldSubrole
        }
        if reading.secureEventInput {
            let holder = reading.secureInputProcessIdentifier.map { "\($0)" } ?? "none"
            summary += "; secure input on, session names pid \(holder)"
        }
        return Probe(
            isTextField: isTextField, summary: summary,
            processIdentifier: reading.processIdentifier,
            secureInput: secureInput(reading, isPasswordField: isPasswordField, isTextField: isTextField)
        )
    }

    /// Whether pasting is unsafe here, and why (F445, F585).
    ///
    /// A password field — the focused element's `AXSecureTextField` subrole, which native, WebKit
    /// and Chromium password fields report — is never pasted into.
    ///
    /// `IsSecureEventInputEnabled()` is the other signal, and on its own it cannot say where:
    /// CarbonEventsCore.h, "whether secure event input is enabled by any process, not just the
    /// current process". F445 read it alone, so Terminal's Secure Keyboard Entry stopped every
    /// paste in every app (F585). The OS does not say which process turned it on (see
    /// `secureInputProcess()`), so it is weighed against what else can be seen:
    ///
    /// 1. The session names no process, or there is no app in front to compare it with: nothing
    ///    shows the app in front did not turn secure input on. Not pasted.
    /// 2. The app in front is the one the session names — read as the app that was in front when
    ///    secure input came on, as it is for a password prompt or Terminal's own setting. Not
    ///    pasted, whatever Accessibility shows: a sudo prompt in Terminal is an ordinary
    ///    `AXTextArea`.
    /// 3. The session names another app, and a focused ordinary text field in the app in front
    ///    vouches that no password field has focus there: pasted. This is the only way through.
    /// 4. Otherwise — no element visible, or not a text field — nothing vouches: not pasted.
    ///
    /// So a paste goes ahead only on two positive readings, and every doubt about either is "not
    /// pasted": a false positive costs a paste, with the text still offered by the pill's Copy,
    /// where a false negative types someone's words into a password prompt. If the session key is
    /// missing, rule 1 gives F445's behaviour; if it names the app in front at the time of the read
    /// rather than when secure input came on, rule 2 does. Neither is worse than F445. Rule 3 is
    /// wrong in two cases nothing here can see: a second process turning secure input on while the
    /// named one still holds it, and an app that turned it on from the background and was brought
    /// to the front afterwards — each with a password prompt Accessibility shows as ordinary text.
    static func secureInput(_ reading: Reading, isPasswordField: Bool, isTextField: Bool) -> SecureInput? {
        if isPasswordField { return .passwordField }
        guard reading.secureEventInput else { return nil }
        guard let holder = reading.secureInputProcessIdentifier,
              let front = reading.processIdentifier,
              holder != front,
              isTextField else {
            return .keyboardEntry(app: reading.secureInputAppName)
        }
        return nil
    }

    /// The live reads behind `probe()`.
    static func read() -> Reading {
        let app = NSWorkspace.shared.frontmostApplication
        var reading = Reading(
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            secureEventInput: IsSecureEventInputEnabled()
        )
        if reading.secureEventInput, let holder = secureInputProcess() {
            reading.secureInputProcessIdentifier = holder
            reading.secureInputAppName = NSRunningApplication(processIdentifier: holder)?.localizedName
        }
        guard let focused = focusedElement(in: app) else { return reading }
        var selection: AnyObject?
        reading.focused = Reading.Element(
            role: string(focused, kAXRoleAttribute),
            subrole: string(focused, kAXSubroleAttribute),
            hasSelectedTextRange: AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, &selection
            ) == .success,
            valueSettable: settable(focused, kAXValueAttribute),
            selectedTextSettable: settable(focused, kAXSelectedTextAttribute)
        )
        return reading
    }

    /// AXUIElement.h: `AXUIElementIsAttributeSettable` reports `kAXErrorAttributeUnsupported`,
    /// `kAXErrorCannotComplete` (often a timeout) and others when it has no answer; each is nil.
    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return nil
        }
        return settable.boolValue
    }

    /// The process the window server names while secure event input is on, or nil.
    ///
    /// Undocumented: CGSession.h documents five keys of `CGSessionCopyCurrentDictionary()` and this
    /// is not one of them. It appears only while secure input is on. And it is not the process
    /// that turned secure input on — measured 2026-09-28 (F585): a background process with no
    /// window called `EnableSecureEventInput()` while Chrome was frontmost, and the key named
    /// Chrome. So it is read as "the app that was in front when secure input came on", never as
    /// the owner. That reading is the likelier one, not a measured one: in that run Chrome was
    /// in front both when secure input came on and when the key was read.
    static func secureInputProcess() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let number = session["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
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
