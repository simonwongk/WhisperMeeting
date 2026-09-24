import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F425, rebuilt by F516 — a dictation paste borrows the clipboard and gives it back when the text
/// went into a text field, and leaves it there when it did not ("只有…没有进到任何输入框的时候，才放
/// 剪切板"). The copy is taken at paste time, as Wispr Flow, Superwhisper and VoiceInk take it.
///
/// Every test that touches a pasteboard uses a private, uniquely named `NSPasteboard`, never
/// `NSPasteboard.general`: a real pasteboard (so `changeCount`, item staleness and the
/// `NSPasteboardItem` deep copy are the system's, not a fake's), but one no other process uses and
/// that holds none of the user's data. The ⌘V is a closure that records the call instead of
/// posting an event, and the restore delay goes through a scheduler the test fires by hand, so no
/// restore waits on a wall clock. The one poll, in the controller test, waits for the
/// transcription task and is required to succeed.

@MainActor
private final class ManualScheduler {
    private(set) var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending.append((delay, work))
    }

    /// Fires everything scheduled so far, in the order it was scheduled.
    func runAll() {
        let due = pending
        pending.removeAll()
        for item in due { item.work() }
    }
}

@MainActor
private final class ClipboardHarness {
    let board = NSPasteboard.withUniqueName()
    let scheduler = ManualScheduler()
    private(set) var pasteCount = 0
    var pasteSucceeds = true
    /// What the focus probe reports: whether a text field has focus when the dictation is pasted.
    var textFieldFocused = true
    static let restoreDelay: TimeInterval = 1.5

    init() throws {
        // The precondition every assertion below rests on. If this host has no working pasteboard
        // server, say that — rather than failing later as a claim about restore behaviour.
        board.clearContents()
        board.setString("probe", forType: .string)
        try #require(board.string(forType: .string) == "probe", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        TextInjector(
            pasteboard: board,
            restoreDelay: Self.restoreDelay,
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in
                FocusedTextField.Probe(isTextField: self.textFieldFocused, summary: "test")
            },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return self.pasteSucceeds
            },
            schedule: { [scheduler] delay, work in scheduler.schedule(delay, work) }
        )
    }

    func put(_ string: String) {
        board.clearContents()
        board.setString(string, forType: .string)
    }

    var text: String? { board.string(forType: .string) }

    /// Each item's types (as UTI strings) and bytes, in the pasteboard's own order.
    var contents: [[(type: String, data: Data?)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.map { ($0.rawValue, item.data(forType: $0)) }
        }
    }

    deinit { board.releaseGlobally() }
}

/// A dictation's delivery, the way the controller drives the injector.
@MainActor
private func dictate(_ text: String, with injector: TextInjector, autoPaste: Bool = true) -> TextInjector.Delivery {
    injector.deliver(text, autoPaste: autoPaste)
}

@MainActor
@Test("Pasted into a text field, the dictation gives the clipboard back once the paste has landed (F516)")
func pasteIntoATextFieldRestoresTheClipboard() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    #expect(dictate("dictated words", with: injector) == .pasted)
    #expect(harness.pasteCount == 1)
    // The paste reads the clipboard, so the dictation must still be there until the restore fires.
    #expect(harness.text == "dictated words")
    try #require(harness.scheduler.pending.count == 1)
    #expect(harness.scheduler.pending.first?.delay == ClipboardHarness.restoreDelay)

    harness.scheduler.runAll()
    #expect(harness.text == "copied on my phone")
}

@MainActor
@Test("With no text field focused, the dictation is left on the clipboard for the user to paste (F516)")
func noTextFieldLeavesTheDictationOnTheClipboard() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.textFieldFocused = false
    harness.put("copied on my phone")

    // Still pasted — the probe can be blind to a field in an app that hides it — but reported as a
    // clipboard delivery, so the user is told the text is on the clipboard.
    #expect(dictate("dictated words", with: injector) == .clipboard)
    #expect(harness.pasteCount == 1)
    #expect(harness.scheduler.pending.isEmpty)
    #expect(harness.text == "dictated words")
}

@MainActor
@Test("The copy is taken at paste time, so something copied while dictating is what comes back (F516)")
func somethingCopiedWhileDictatingIsRestored() throws {
    // F425 read the clipboard when recording STARTED and refused to restore one that changed during
    // the dictation — exactly what an item arriving from the iPhone mid-dictation does.
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied before dictating")
    harness.put("copied on my phone while dictating")

    #expect(dictate("dictated words", with: injector) == .pasted)
    harness.scheduler.runAll()
    #expect(harness.text == "copied on my phone while dictating")
}

@MainActor
@Test("Anything written to the clipboard after the paste wins over the restore (F425)")
func somethingCopiedAfterThePasteIsNotOverwritten() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    #expect(dictate("dictated words", with: injector) == .pasted)
    harness.put("copied a moment later")
    harness.scheduler.runAll()

    #expect(harness.text == "copied a moment later")
}

@MainActor
@Test("Clipboard-only delivery leaves the dictation on the clipboard, because that is the delivery (F425)")
func clipboardOnlyDeliveryIsNeverRestored() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()

    harness.put("copied on my phone")
    #expect(dictate("auto-paste off", with: injector, autoPaste: false) == .clipboard)
    harness.scheduler.runAll()
    #expect(harness.text == "auto-paste off")
    #expect(harness.pasteCount == 0)

    harness.put("copied on my phone")
    harness.pasteSucceeds = false
    #expect(dictate("no accessibility", with: injector) == .clipboard)
    harness.scheduler.runAll()
    #expect(harness.text == "no accessibility")
}

@MainActor
@Test("The borrowed clipboard item is marked transient, so clipboard history skips it (F516)")
func theBorrowedItemIsMarkedTransient() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    #expect(dictate("dictated words", with: injector) == .pasted)
    let types = harness.contents.flatMap { $0.map(\.type) }
    #expect(types.contains("org.nspasteboard.TransientType"))
    #expect(types.contains("org.nspasteboard.AutoGeneratedType"))

    // Left on the clipboard for the user, it is an ordinary copy: they may want it in their history.
    harness.textFieldFocused = false
    #expect(dictate("left for the user", with: injector) == .clipboard)
    #expect(!harness.contents.flatMap { $0.map(\.type) }.contains("org.nspasteboard.TransientType"))
}

@MainActor
@Test("Every item and every representation round-trips, in order (F425)")
func multiTypeItemsRoundTrip() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    let custom = NSPasteboard.PasteboardType("com.whispermeet.tests.private-representation")
    let first = NSPasteboardItem()
    #expect(first.setString("plain", forType: .string))
    #expect(first.setData(Data("<b>rich</b>".utf8), forType: .html))
    #expect(first.setData(Data([0, 1, 2, 254, 255]), forType: custom))
    let second = NSPasteboardItem()
    #expect(second.setString("second item", forType: .string))
    harness.board.clearContents()
    #expect(harness.board.writeObjects([first, second]))
    let before = harness.contents
    try #require(before.count == 2)

    #expect(dictate("dictated words", with: injector) == .pasted)
    #expect(harness.text == "dictated words")
    harness.scheduler.runAll()

    let after = harness.contents
    #expect(after.map { $0.map(\.type) } == before.map { $0.map(\.type) })
    #expect(after.map { $0.map(\.data) } == before.map { $0.map(\.data) })
}

@MainActor
@Test("An empty clipboard is restored to empty, not left holding the dictation (F425)")
func emptyClipboardRestoresToEmpty() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.board.clearContents()
    try #require(harness.contents.isEmpty)

    #expect(dictate("dictated words", with: injector) == .pasted)
    #expect(harness.text == "dictated words")
    harness.scheduler.runAll()
    #expect(harness.contents.isEmpty)
}

@MainActor
@Test("A clipboard a password manager marked concealed is never copied, so it is not restored (F425)")
func concealedClipboardIsNotHeld() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    let item = NSPasteboardItem()
    #expect(item.setString("hunter2", forType: .string))
    #expect(item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    harness.board.clearContents()
    #expect(harness.board.writeObjects([item]))

    #expect(dictate("dictated words", with: injector) == .pasted)
    harness.scheduler.runAll()
    #expect(harness.text == "dictated words")
}

@MainActor
@Test("A second dictation before the first restore still ends with the user's clipboard (F516)")
func rapidSecondDictationRestoresTheOriginal() throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    #expect(dictate("first sentence", with: injector) == .pasted)
    // The clipboard now holds the first dictation; the second must not take THAT as the user's.
    #expect(dictate("second sentence", with: injector) == .pasted)
    #expect(harness.text == "second sentence")
    harness.scheduler.runAll()

    #expect(harness.text == "copied on my phone")
}

/// Pins the decision in `TextInjector.allowsSnapshot(accessBehavior:)`: the private pasteboard the
/// other tests use always allows access, so this is the only place `.ask` and `.alwaysDeny` are
/// exercised. Before macOS 15.4 the setting does not exist and there is nothing to check.
@Test("The clipboard is not read for a snapshot where the system would ask first or refuse (F425)")
func clipboardIsNotReadWhereTheSystemWouldAskOrRefuse() {
    guard #available(macOS 15.4, *) else { return }
    #expect(TextInjector.allowsSnapshot(accessBehavior: .alwaysAllow))
    #expect(TextInjector.allowsSnapshot(accessBehavior: .default))
    #expect(!TextInjector.allowsSnapshot(accessBehavior: .ask))
    #expect(!TextInjector.allowsSnapshot(accessBehavior: .alwaysDeny))
}

/// The reachable path: the hotkey's press and release drive a real `DictationController`, whose
/// delivery reaches the injector. Every call into the injector comes from the controller.
@MainActor
@Test("A hotkey dictation with auto-paste on gives the clipboard back after pasting (F425, F516)")
func hotkeyDictationRestoresClipboard() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    let suite = "WhisperMeet.DictationClipboardRestoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationClipboardRestoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "dictated words"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: injector,
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    harness.put("copied on my phone")

    monitor.onPressStart?()
    monitor.onPressEnd?()
    // The polled value is the precondition, so it is required, not merely expected.
    for _ in 0..<1_000 where controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let entry = try #require(controller.logStore.log.entries.first)

    #expect(entry.outcome == .pasted)
    #expect(harness.pasteCount == 1)
    #expect(harness.text == "dictated words")
    harness.scheduler.runAll()
    #expect(harness.text == "copied on my phone")
}
