import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F445 — a dictation is pasted with ⌘V into whatever has focus when the transcript is ready, which
/// is not necessarily where the user was when they pressed the key. Two cases are refused:
///
/// 1. The app in front is not the app the dictation was started in (the user ⌘-Tabbed while it was
///    transcribing). The text is left on the clipboard and the pill says why, instead of landing in
///    another conversation or a terminal.
/// 2. Secure input — a password field has focus, or a process has secure keyboard entry on — at the
///    press or at delivery. The text is never pasted (a password prompt that grabbed focus would
///    otherwise receive a sentence as a password) and never written to dictation-log.json. It is
///    left on the clipboard marked concealed and transient, the nspasteboard.org markers that tell
///    clipboard-history tools not to record it, so a dictation meant for somewhere else is not lost.
///
/// Private pasteboards and a closure standing in for ⌘V, as in `DictationClipboardRestoreTests`.

@MainActor
private final class TargetHarness {
    let board = NSPasteboard.withUniqueName()
    private(set) var pasteCount = 0
    /// What the focus probe reports each time it is asked.
    var probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100)

    init() throws {
        board.clearContents()
        board.setString("probe", forType: .string)
        try #require(board.string(forType: .string) == "probe", "the private pasteboard does not round-trip a string on this host")
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
            schedule: { _, _ in }
        )
    }

    var text: String? { board.string(forType: .string) }
    var types: [String] { (board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) } }

    deinit { board.releaseGlobally() }
}

private let concealed = "org.nspasteboard.ConcealedType"
private let transient = "org.nspasteboard.TransientType"

@MainActor
@Test("A dictation whose app is no longer in front is left on the clipboard, not pasted (F445)")
func dictationForAnotherAppIsNotPasted() throws {
    let harness = try TargetHarness()
    let injector = harness.makeInjector()
    let pressedIn = injector.target()            // pid 100, where the key was pressed
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 200)

    #expect(injector.deliver("for the first chat", autoPaste: true, pressedIn: pressedIn) == .appChanged)
    #expect(harness.pasteCount == 0)
    #expect(harness.text == "for the first chat")
    // An ordinary copy: it is the user's to paste, and their clipboard history may keep it.
    #expect(!harness.types.contains(transient))
}

@MainActor
@Test("A dictation delivered to the app it was started in is still pasted (F445)")
func dictationForTheSameAppIsPasted() throws {
    let harness = try TargetHarness()
    let injector = harness.makeInjector()
    let pressedIn = injector.target()

    #expect(injector.deliver("same app", autoPaste: true, pressedIn: pressedIn) == .pasted)
    #expect(harness.pasteCount == 1)
}

@MainActor
@Test("Secure input at delivery: nothing is pasted, and the text is left concealed (F445)")
func secureInputAtDeliveryIsNeverPasted() throws {
    let harness = try TargetHarness()
    let injector = harness.makeInjector()
    let pressedIn = injector.target()
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100, isSecure: true)

    #expect(injector.deliver("not a password", autoPaste: true, pressedIn: pressedIn) == .secureInput)
    #expect(harness.pasteCount == 0)
    #expect(harness.text == "not a password")
    #expect(harness.types.contains(concealed))
    #expect(harness.types.contains(transient))
}

@MainActor
@Test("Secure input at the press is honoured even with auto-paste off (F445)")
func secureInputAtThePressIsNeverPastedOrKept() throws {
    let harness = try TargetHarness()
    let injector = harness.makeInjector()
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100, isSecure: true)
    let pressedIn = injector.target()
    harness.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100)

    #expect(injector.deliver("hunter2", autoPaste: true, pressedIn: pressedIn) == .secureInput)
    #expect(harness.pasteCount == 0)
    // With auto-paste off the clipboard IS the delivery, but it is still a secure one.
    #expect(injector.deliver("hunter2", autoPaste: false, pressedIn: pressedIn) == .secureInput)
    #expect(harness.types.contains(concealed))
}

// MARK: - Through the controller

@MainActor
private final class PhaseLog: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private struct DeliveryHarness {
    let targets: TargetHarness
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let overlay: PhaseLog
    let cleanup: () -> Void

    init() throws {
        let suite = "WhisperMeet.DictationDeliveryTargetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationDeliveryTargetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(true, forKey: "dictationAutoPaste")
        targets = try TargetHarness()
        monitor = FakeHotkeyMonitor()
        overlay = PhaseLog()
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: targets.makeInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Press, then let `whileSpeaking` change the world, then release and wait for delivery — which
    /// is when the dismiss is scheduled and `status` stops being `.transcribing`.
    func dictate(whileSpeaking: () -> Void) async throws {
        monitor.onPressStart?()
        whileSpeaking()
        monitor.onPressEnd?()
        for _ in 0..<1_000 where controller.status == .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.status != .transcribing, "the dictation never delivered")
    }
}

@MainActor
@Test("The controller checks the app the key was pressed in, and says so when it moved (F445)")
func controllerLeavesAMovedDictationOnTheClipboard() async throws {
    let harness = try DeliveryHarness()
    defer { harness.cleanup() }

    try await harness.dictate {
        harness.targets.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 200)
    }

    #expect(harness.targets.pasteCount == 0)
    #expect(harness.targets.text == "dictated words")
    #expect(harness.overlay.phases.last == .appChanged)
    let entry = try #require(harness.controller.logStore.log.entries.first)
    #expect(entry.outcome == .clipboard)
}

@MainActor
@Test("A dictation made into a password field is neither pasted nor written to the history (F445)")
func controllerKeepsSecureDictationOutOfTheLog() async throws {
    let harness = try DeliveryHarness()
    defer { harness.cleanup() }
    harness.targets.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100, isSecure: true)

    try await harness.dictate {}

    #expect(harness.targets.pasteCount == 0)
    #expect(harness.overlay.phases.last == .secureInput)
    #expect(harness.controller.logStore.log.entries.isEmpty)
}
