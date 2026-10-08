import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F586 — F445 kept a dictation made into secure input out of the history, but still wrote it to
/// the general pasteboard. The nspasteboard.org Concealed and Transient markers it carried are
/// advisory: clipboard managers honour them, the OS does not, so any process reading the clipboard
/// saw the words the app had itself judged might be a password.
///
/// The user's decision, 2026-09-28 (chosen from three: this; discard entirely; keep today's
/// behaviour): never write it automatically. The pill says "Not pasted — secure input" and offers
/// Copy; the text is held in memory only while that pill shows, then dropped. Copy is the user's
/// own act, so it writes the pasteboard, still concealed and transient.
///
/// Private pasteboards and a counter for ⌘V. The overlay stand-in keeps the Copy action the
/// controller gives it, so pressing "Copy" here runs exactly what the pill's button runs.

private let concealed = "org.nspasteboard.ConcealedType"
private let transient = "org.nspasteboard.TransientType"

@MainActor
private final class SecureCopyHarness {
    let board = NSPasteboard.withUniqueName()
    private(set) var pasteCount = 0
    var probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100, secureInput: .passwordField)
    private(set) var restores: [@MainActor () -> Void] = []

    init() throws {
        board.clearContents()
        board.setString("copied on my phone", forType: .string)
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        TextInjector(
            pasteboard: board,
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in self.probe },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { [unowned self] _, work in self.restores.append(work) }
        )
    }

    var text: String? { board.string(forType: .string) }
    var types: [String] { (board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) } }

    func runRestores() {
        let due = restores
        restores.removeAll()
        for work in due { work() }
    }

    deinit { board.releaseGlobally() }
}

@MainActor
private final class CopyButtonOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    private(set) var hides = 0
    var onCopy: (() -> Void)?
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() { hides += 1 }
}

// MARK: - The injector

@MainActor
@Test("A dictation made into secure input is not written to the clipboard, at the press or at delivery (F586)")
func secureInputWritesNothingToTheClipboard() throws {
    let harness = try SecureCopyHarness()
    let injector = harness.makeInjector()
    let before = harness.board.changeCount

    // Secure at delivery.
    #expect(injector.deliver("hunter2", autoPaste: true, pressedIn: nil) == .secureInput)
    // Secure only at the press, with auto-paste on and off.
    let pressedIn = injector.target()
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100)
    #expect(injector.deliver("hunter2", autoPaste: true, pressedIn: pressedIn) == .secureInput)
    #expect(injector.deliver("hunter2", autoPaste: false, pressedIn: pressedIn) == .secureInput)

    #expect(harness.board.changeCount == before)
    #expect(harness.text == "copied on my phone")
    #expect(harness.pasteCount == 0)
}

@MainActor
@Test("A secure dictation does not cancel the previous paste's clipboard restore (F586)")
func secureInputLeavesAnOwedRestoreAlone() throws {
    let harness = try SecureCopyHarness()
    let injector = harness.makeInjector()
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100)
    #expect(injector.deliver("first sentence", autoPaste: true) == .pasted)
    try #require(harness.restores.count == 1)

    // A password prompt takes focus before the first restore has run.
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100, secureInput: .passwordField)
    #expect(injector.deliver("hunter2", autoPaste: true) == .secureInput)
    harness.runRestores()

    #expect(harness.text == "copied on my phone")
}

@MainActor
@Test("Copy writes the dictation, concealed and transient (F586)")
func copyWritesTheDictationConcealed() throws {
    let harness = try SecureCopyHarness()
    let injector = harness.makeInjector()

    injector.copyConcealed("dictated words")

    #expect(harness.text == "dictated words")
    #expect(harness.types.contains(concealed))
    #expect(harness.types.contains(transient))
}

// MARK: - Through the controller

@MainActor
private struct SecureCopyController {
    let harness: SecureCopyHarness
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let overlay: CopyButtonOverlay
    let cleanup: () -> Void
    private(set) var notices: () -> Int

    init(secureCopyWindow: TimeInterval? = nil) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationSecureCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(true, forKey: "dictationAutoPaste")
        harness = try SecureCopyHarness()
        monitor = FakeHotkeyMonitor()
        overlay = CopyButtonOverlay()
        controller = DictationController(
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
        if let secureCopyWindow { controller.secureCopyWindow = secureCopyWindow }
        var count = 0
        controller.clipboardNotifier = { count += 1 }
        notices = { count }
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Press and release, then wait — against the wall clock, with a cap that only bounds a hang —
    /// for the secure pill, which is the delivery's last visible step.
    func dictate() async throws {
        monitor.onPressStart?()
        monitor.onPressEnd?()
        let deadline = Date().addingTimeInterval(30)
        while !overlay.phases.contains(.secureInput), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(overlay.phases.contains(.secureInput), "the secure pill never showed")
    }
}

@MainActor
@Test("A secure dictation is held for the pill's Copy button, and nowhere else (F586)")
func aSecureDictationIsHeldForCopyOnly() async throws {
    let setup = try SecureCopyController()
    defer { setup.cleanup() }
    let before = setup.harness.board.changeCount

    try await setup.dictate()

    #expect(setup.overlay.phases.last == .secureInput)
    #expect(setup.controller.heldSecureDictation == "dictated words")
    #expect(setup.harness.board.changeCount == before)
    #expect(setup.notices() == 0)
    #expect(setup.controller.logStore.log.entries.isEmpty)

    // The pill's button.
    let copy = try #require(setup.overlay.onCopy, "the controller gave the pill no Copy action")
    copy()

    #expect(setup.harness.text == "dictated words")
    #expect(setup.harness.types.contains(concealed))
    #expect(setup.harness.types.contains(transient))
    #expect(setup.controller.heldSecureDictation == nil)
    #expect(setup.overlay.phases.last == .copied)
    #expect(setup.controller.logStore.log.entries.isEmpty)
}

@MainActor
@Test("The held dictation is dropped when the pill goes away on its own (F586)")
func theHeldDictationIsDroppedWhenThePillGoes() async throws {
    let setup = try SecureCopyController(secureCopyWindow: 0.05)
    defer { setup.cleanup() }
    let before = setup.harness.board.changeCount

    try await setup.dictate()
    // The dismiss is the subject: wait for the pill to be taken down, then for nothing to be held.
    let deadline = Date().addingTimeInterval(30)
    while setup.overlay.hides == 0 || setup.controller.heldSecureDictation != nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(setup.overlay.hides > 0, "the pill was never taken down")

    #expect(setup.controller.heldSecureDictation == nil)
    // And Copy after that writes nothing.
    setup.overlay.onCopy?()
    #expect(setup.harness.board.changeCount == before)
}

/// The one link no test above reaches: the pill's SwiftUI button, which this target cannot render
/// (F174). Asserted against the source with comments stripped (F285), so a paragraph describing the
/// button cannot stand in for it. The runtime half — the controller hands the overlay a Copy action
/// that copies — is `aSecureDictationIsHeldForCopyOnly`.
@Test("The pill shows a Copy button for secure input, calls the controller's action, and takes clicks only then (F586)")
func thePillsCopyButtonIsWired() throws {
    let overlay = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationOverlay.swift")
    #expect(overlay.contains("if model.phase.offersCopy {"))
    #expect(overlay.contains(#"Button("Copy") { model.onCopy?() }"#))
    #expect(overlay.contains("didSet { model.onCopy = onCopy }"))
    #expect(overlay.contains("panel?.ignoresMouseEvents = !phase.offersCopy"))
    #expect(overlay.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"))
    #expect(overlay.contains("FirstClickHostingView(rootView: DictationPill(model: model))"))

    let controller = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    #expect(controller.contains("self.overlay.onCopy = { [weak self] in self?.copyHeldSecureDictation() }"))
}

@MainActor
@Test("The held dictation is dropped when the next dictation starts, or dictation is turned off (F586)")
func theHeldDictationIsDroppedByTheNextPressOrDisabling() async throws {
    let setup = try SecureCopyController()
    defer { setup.cleanup() }

    try await setup.dictate()
    try #require(setup.controller.heldSecureDictation == "dictated words")
    setup.monitor.onPressStart?()
    #expect(setup.overlay.phases.last == .listening)
    #expect(setup.controller.heldSecureDictation == nil)

    let second = try SecureCopyController()
    defer { second.cleanup() }
    try await second.dictate()
    try #require(second.controller.heldSecureDictation == "dictated words")
    second.controller.setEnabled(false)
    #expect(second.controller.heldSecureDictation == nil)
}
