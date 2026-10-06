import AppKit
import ApplicationServices
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F585 — `IsSecureEventInputEnabled()` is system-wide (CarbonEventsCore.h: "whether secure event
/// input is enabled by any process"), so F445's check, which read it alone, refused every paste in
/// every app while Terminal's Secure Keyboard Entry was on, and the pill blamed "secure input"
/// without saying whose.
///
/// The judgement runs over a `FocusedTextField.Reading` — what the probe read from the system — so
/// each case here goes through the real `probe(reading:)` and the real `TextInjector.deliver`; only
/// the reads, the pasteboard (a private one) and the ⌘V (a counter) are stand-ins.

private let terminal: pid_t = 100
private let textEdit: pid_t = 200

@MainActor
private final class SecureEntryHarness {
    let board = NSPasteboard.withUniqueName()
    private(set) var pasteCount = 0
    var reading = FocusedTextField.Reading(
        bundleIdentifier: "com.apple.TextEdit",
        processIdentifier: textEdit,
        focused: .init(role: kAXTextAreaRole, subrole: nil, hasSelectedTextRange: true),
        secureEventInput: true,
        secureInputProcessIdentifier: terminal,
        secureInputAppName: "Terminal"
    )

    init() throws {
        board.clearContents()
        board.setString("probe", forType: .string)
        try #require(board.string(forType: .string) == "probe", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        TextInjector(
            pasteboard: board,
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in FocusedTextField.probe(reading: self.reading) },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { _, _ in }
        )
    }

    /// Press and deliver in the same state, as a dictation that nobody moved away from.
    func dictate(_ text: String = "dictated words") -> TextInjector.Delivery {
        let injector = makeInjector()
        let pressedIn = injector.target()
        return injector.deliver(text, autoPaste: true, pressedIn: pressedIn)
    }

    deinit { board.releaseGlobally() }
}

@MainActor
@Test("Secure Keyboard Entry held by another app does not stop a paste into an ordinary text field (F585)")
func secureEntryElsewhereStillPastesIntoATextField() throws {
    let harness = try SecureEntryHarness()

    #expect(harness.dictate() == .pasted)
    #expect(harness.pasteCount == 1)
}

@MainActor
@Test("A password field is never pasted into, whoever holds secure input (F585)")
func aPasswordFieldIsStillNeverPasted() throws {
    let harness = try SecureEntryHarness()
    harness.reading.focused = .init(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, hasSelectedTextRange: true)

    #expect(harness.dictate() == .secureInput)
    #expect(harness.pasteCount == 0)
}

@MainActor
@Test("The app in front when secure input came on is not pasted into, and the pill names it (F585)")
func theAppHoldingSecureEntryIsNotPastedInto() throws {
    let harness = try SecureEntryHarness()
    // Terminal in front, its own AXTextArea focused: an ordinary text role, but a sudo prompt in it
    // looks exactly the same to Accessibility.
    harness.reading.bundleIdentifier = "com.apple.Terminal"
    harness.reading.processIdentifier = terminal

    #expect(harness.dictate() == .secureKeyboardEntry(app: "Terminal"))
    #expect(harness.pasteCount == 0)
}

@MainActor
@Test("A field Accessibility cannot see is not pasted into while another app holds secure input (F585)")
func aHiddenFieldIsNotPastedIntoWhileSecureEntryIsOn() throws {
    let harness = try SecureEntryHarness()
    harness.reading.focused = nil

    #expect(harness.dictate() == .secureKeyboardEntry(app: "Terminal"))
    #expect(harness.pasteCount == 0)
}

/// The review's must-fix: the session key is undocumented, so it can be missing, 0, of the wrong
/// type, or a number that names no running app; and there can be no app in front. Then nothing says
/// the app in front did not turn secure input on — a sudo prompt under Secure Keyboard Entry is an
/// ordinary `AXTextArea` — so the flag stands, which is F445's behaviour. Pasting there was the
/// destructive fallback.
@MainActor
@Test("With no process named for secure input, even an ordinary text field is not pasted into (F585)")
func withNoHolderSecureInputRefuses() throws {
    let harness = try SecureEntryHarness()
    harness.reading.secureInputProcessIdentifier = nil
    harness.reading.secureInputAppName = nil
    #expect(harness.dictate() == .secureInput)

    harness.reading.focused = nil
    #expect(harness.dictate() == .secureInput)
    #expect(harness.pasteCount == 0)
}

/// The lane J round-2 review's probe (`reviewJ2KeyNamingNoAppIsWeighedAway`), kept as the RED: a
/// key holding a positive number that resolves to no running app — a pid that has exited, or a
/// future macOS storing something else there — never equals the app in front, so rule 2 could not
/// fire and Terminal's own sudo prompt, with Terminal in front, was pasted into.
@MainActor
@Test("A session key that names no running app counts as no holder, so the app in front is not pasted into (F585)")
func aKeyNamingNoRunningAppRefuses() throws {
    let harness = try SecureEntryHarness()
    harness.reading.bundleIdentifier = "com.apple.Terminal"
    harness.reading.processIdentifier = terminal
    harness.reading.secureInputProcessIdentifier = 2_000_000_000
    harness.reading.secureInputAppName = nil   // `read()` resolves no NSRunningApplication for it

    #expect(FocusedTextField.probe(reading: harness.reading).secureInput != nil)
    #expect(harness.dictate() == .secureInput)
    #expect(harness.pasteCount == 0)
}

@MainActor
@Test("With no app in front to compare, secure input is not weighed away (F585)")
func withNoFrontAppSecureInputRefuses() throws {
    let harness = try SecureEntryHarness()
    harness.reading.processIdentifier = nil

    #expect(harness.dictate() == .secureKeyboardEntry(app: "Terminal"))
    #expect(harness.pasteCount == 0)
}

/// The caption names the app the session key names, and the F585 measurement showed that is not
/// the process that turned secure input on — so it must not say the setting is "on in" that app.
@Test("The secure pill's caption names the app only as the one in front when secure input came on (F585)")
func theSecurePillsCaptionDoesNotClaimAnOwner() throws {
    let caption = try #require(DictationOverlay.Phase.secureKeyboardEntry(app: "Terminal").caption)
    #expect(caption == "It came on while Terminal was in front")
    #expect(!caption.contains("is on in"))
    #expect(DictationOverlay.Phase.secureInput.caption == nil)
}

@MainActor
@Test("With secure input off, nothing about it stops a paste (F585)")
func secureInputOffIsNotSecure() throws {
    let harness = try SecureEntryHarness()
    harness.reading = FocusedTextField.Reading(
        bundleIdentifier: "com.apple.Terminal",
        processIdentifier: terminal,
        focused: .init(role: kAXTextAreaRole, subrole: nil, hasSelectedTextRange: true)
    )

    #expect(harness.dictate() == .pasted)
}

@MainActor
@Test("Secure keyboard entry at the press is honoured at delivery, and named (F585)")
func secureEntryAtThePressIsNamedAtDelivery() throws {
    let harness = try SecureEntryHarness()
    harness.reading.bundleIdentifier = "com.apple.Terminal"
    harness.reading.processIdentifier = terminal
    let injector = harness.makeInjector()
    let pressedIn = injector.target()
    harness.reading.secureEventInput = false
    harness.reading.secureInputProcessIdentifier = nil
    harness.reading.secureInputAppName = nil

    #expect(injector.deliver("words", autoPaste: true, pressedIn: pressedIn) == .secureKeyboardEntry(app: "Terminal"))
    #expect(harness.pasteCount == 0)
}

// MARK: - Through the controller

@MainActor
private final class SecureEntryPhaseLog: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private func dictateThroughTheController(_ harness: SecureEntryHarness) async throws -> (DictationController, SecureEntryPhaseLog, () -> Void) {
    let suite = "WhisperMeet.SecureKeyboardEntryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecureKeyboardEntryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cleanup = {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let overlay = SecureEntryPhaseLog()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "dictated words"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: overlay,
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: harness.makeInjector(),
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    monitor.onPressStart?()
    monitor.onPressEnd?()
    // The delivery is the subject; the wall-clock cap only bounds a hang, and it must be met.
    let deadline = Date().addingTimeInterval(30)
    while controller.status == .transcribing, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(controller.status != .transcribing, "the dictation never delivered")
    return (controller, overlay, cleanup)
}

@MainActor
@Test("The pill names the app in front when secure input came on, and the dictation stays out of the history (F585)")
func controllerNamesTheAppHoldingSecureEntry() async throws {
    let harness = try SecureEntryHarness()
    harness.reading.bundleIdentifier = "com.apple.Terminal"
    harness.reading.processIdentifier = terminal
    let (controller, overlay, cleanup) = try await dictateThroughTheController(harness)
    defer { cleanup() }

    #expect(harness.pasteCount == 0)
    #expect(overlay.phases.last == .secureKeyboardEntry(app: "Terminal"))
    #expect(controller.logStore.log.entries.isEmpty)
}

@MainActor
@Test("With Terminal's Secure Keyboard Entry on, a dictation into TextEdit is pasted and recorded (F585)")
func controllerPastesIntoAnotherAppWhileSecureEntryIsOn() async throws {
    let harness = try SecureEntryHarness()
    let (controller, overlay, cleanup) = try await dictateThroughTheController(harness)
    defer { cleanup() }

    #expect(harness.pasteCount == 1)
    #expect(overlay.phases.last == .done)
    #expect(controller.logStore.log.entries.first?.outcome == .pasted)
}
