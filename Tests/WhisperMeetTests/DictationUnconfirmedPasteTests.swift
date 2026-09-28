import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F600 — `TextInjector.deliver` posts ⌘V and only then looks at the focus probe; with no text field
/// visible it returned `.clipboard`, so the controller showed "Copied to clipboard", posted "press ⌘V
/// to paste" and recorded a clipboard-only delivery for a dictation that had already been pasted. An
/// app that hides its field from Accessibility (F516's Gap names Warp and the Claude app) then got
/// the text twice from a user who did what the notice said.
///
/// A private pasteboard and a counter standing in for ⌘V, as in `DictationClipboardRestoreTests`.

@MainActor
private final class UnconfirmedPasteHarness {
    let board = NSPasteboard.withUniqueName()
    private(set) var pasteCount = 0
    private(set) var notices = 0
    private(set) var phases: [DictationOverlay.Phase] = []
    var textFieldFocused = false

    init() throws {
        board.clearContents()
        board.setString("copied on my phone", forType: .string)
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        TextInjector(
            pasteboard: board,
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in
                FocusedTextField.Probe(isTextField: self.textFieldFocused, summary: "test", processIdentifier: 100)
            },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { _, _ in }
        )
    }

    func noticePosted() { notices += 1 }
    func showed(_ phase: DictationOverlay.Phase) { phases.append(phase) }

    deinit { board.releaseGlobally() }
}

@MainActor
private final class RecordingOverlay: DictationOverlayPresenting {
    let onShow: (DictationOverlay.Phase) -> Void
    init(onShow: @escaping (DictationOverlay.Phase) -> Void) { self.onShow = onShow }
    func show(_ phase: DictationOverlay.Phase) { onShow(phase) }
    func update(level: Float) {}
    func hide() {}
}

/// A hotkey dictation, driven from the fake monitor through a real `DictationController`, until it
/// has been recorded in the history (the delivery's last step), required within a wall-clock cap.
@MainActor
private func dictate(
    _ harness: UnconfirmedPasteHarness, autoPaste: Bool = true
) async throws -> (entry: DictationLogEntry, cleanup: () -> Void) {
    let suite = "WhisperMeet.DictationUnconfirmedPasteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationUnconfirmedPasteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cleanup = {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(autoPaste, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "dictated words"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: RecordingOverlay { [unowned harness] in harness.showed($0) },
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: harness.makeInjector(),
        activateOnInit: false
    )
    controller.clipboardNotifier = { [unowned harness] in harness.noticePosted() }
    monitor.onPressStart?()
    monitor.onPressEnd?()
    let deadline = Date().addingTimeInterval(30)
    while controller.logStore.log.entries.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let entry = try #require(controller.logStore.log.entries.first, "the dictation was never recorded")
    return (entry, cleanup)
}

@MainActor
@Test("A paste sent with no text field in view is reported as pasted, with no 'press ⌘V' notice (F600)")
func aPasteNoFieldWasSeenToTakeIsNotReportedAsACopy() async throws {
    let harness = try UnconfirmedPasteHarness()
    let (entry, cleanup) = try await dictate(harness)
    defer { cleanup() }

    #expect(harness.pasteCount == 1)
    #expect(harness.notices == 0)
    #expect(harness.phases.last == .pastedUnconfirmed)
    #expect(entry.outcome == .pasted)
    // F516's rule stands: nothing to give back to, so the dictation stays on the clipboard.
    #expect(harness.board.string(forType: .string) == "dictated words")
}

@MainActor
@Test("A clipboard-only dictation still says it is on the clipboard (F600 leaves it alone)")
func aClipboardOnlyDictationStillPostsTheNotice() async throws {
    let harness = try UnconfirmedPasteHarness()
    let (entry, cleanup) = try await dictate(harness, autoPaste: false)
    defer { cleanup() }

    #expect(harness.pasteCount == 0)
    #expect(harness.notices == 1)
    #expect(harness.phases.last == .copied)
    #expect(entry.outcome == .clipboard)
}

/// The persisted-schema half of F600 (AGENTS.md, F188): the new delivery adds no value to
/// `dictation-log.json`. Its entry is written as `{"pasted":{}}` with no `outcomeKind`, the bytes
/// every build since the log existed reads as a paste — so the previous build reads it exactly, and
/// this build reads back what it wrote.
@MainActor
@Test("An unconfirmed paste is written to the history in the shape every earlier build reads (F600)")
func anUnconfirmedPasteAddsNothingToTheHistorysWireFormat() async throws {
    let harness = try UnconfirmedPasteHarness()
    let (entry, cleanup) = try await dictate(harness)
    defer { cleanup() }

    let bytes = try JSONEncoder().encode(entry)
    let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let outcome = try #require(object["outcome"] as? [String: Any])
    #expect(Set(outcome.keys) == ["pasted"])
    #expect((outcome["pasted"] as? [String: Any])?.isEmpty == true)
    #expect(object["outcomeKind"] == nil)

    let decoded = try JSONDecoder().decode(DictationLogEntry.self, from: bytes)
    #expect(decoded.outcome == .pasted)
    #expect(!decoded.wasRecordedByANewerBuild)
}
