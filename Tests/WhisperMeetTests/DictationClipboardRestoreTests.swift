import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F425 — a dictation paste borrows the clipboard and must give it back.
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
    static let restoreDelay: TimeInterval = 1.5

    init() throws {
        // The precondition every assertion below rests on. If this host has no working pasteboard
        // server, say that — rather than failing later as a claim about restore behaviour.
        board.clearContents()
        board.setString("probe", forType: .string)
        try #require(board.string(forType: .string) == "probe", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector(maximumSnapshotBytes: Int = TextInjector.defaultMaximumSnapshotBytes) -> TextInjector {
        TextInjector(
            pasteboard: board,
            restoreDelay: Self.restoreDelay,
            maximumSnapshotBytes: maximumSnapshotBytes,
            canSynthesizePaste: { true },
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

/// A dictation, start to delivery, the way the controller drives the injector.
@MainActor
private func dictate(_ text: String, with injector: TextInjector, autoPaste: Bool = true) async -> TextInjector.Delivery {
    injector.captureWillStart(autoPaste: autoPaste)
    await injector.snapshotRead?.value
    return injector.deliver(text, autoPaste: autoPaste)
}

@MainActor
@Test("A dictation paste puts the previous clipboard back once the paste has had time to land (F425)")
func dictationPasteRestoresPreviousClipboard() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    let delivery = await dictate("dictated words", with: injector)

    #expect(delivery == .pasted)
    #expect(harness.pasteCount == 1)
    // The paste reads the clipboard, so the dictation must still be there until the restore fires.
    #expect(harness.text == "dictated words")
    try #require(harness.scheduler.pending.count == 1)
    #expect(harness.scheduler.pending.first?.delay == ClipboardHarness.restoreDelay)

    harness.scheduler.runAll()
    #expect(harness.text == "copied on my phone")
}

@MainActor
@Test("Anything written to the clipboard after the paste wins over the restore (F425)")
func somethingCopiedAfterThePasteIsNotOverwritten() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    #expect(await dictate("dictated words", with: injector) == .pasted)
    harness.put("copied a moment later")
    harness.scheduler.runAll()

    #expect(harness.text == "copied a moment later")
}

@MainActor
@Test("Clipboard-only delivery leaves the dictation on the clipboard, because that is the delivery (F425)")
func clipboardOnlyDeliveryIsNeverRestored() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()

    harness.put("copied on my phone")
    #expect(await dictate("auto-paste off", with: injector, autoPaste: false) == .clipboard)
    harness.scheduler.runAll()
    #expect(harness.text == "auto-paste off")
    #expect(harness.pasteCount == 0)

    // Auto-paste on, but no ⌘V could be synthesized (no Accessibility): the same thing.
    harness.put("copied on my phone")
    harness.pasteSucceeds = false
    #expect(await dictate("no accessibility", with: injector) == .clipboard)
    harness.scheduler.runAll()
    #expect(harness.text == "no accessibility")
}

@MainActor
@Test("A clipboard that changed during the dictation is not restored over (F425)")
func clipboardChangedDuringDictationIsNotRestored() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied before dictating")

    injector.captureWillStart(autoPaste: true)
    await injector.snapshotRead?.value
    harness.put("copied while dictating")
    #expect(injector.deliver("dictated words", autoPaste: true) == .pasted)
    harness.scheduler.runAll()

    // Neither version is resurrected: the snapshot no longer describes the clipboard, and the
    // content that replaced it was never read.
    #expect(harness.text == "dictated words")
}

@MainActor
@Test("A snapshot still being read when the paste happens is not used (F425)")
func snapshotStillReadingAtDeliveryIsDiscarded() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.put("copied on my phone")

    injector.captureWillStart(autoPaste: true)
    let read = injector.snapshotRead
    // No suspension between the two calls, so the read cannot have reported back to the main actor.
    #expect(injector.deliver("dictated words", autoPaste: true) == .pasted)
    await read?.value
    harness.scheduler.runAll()

    #expect(harness.text == "dictated words")
}

@MainActor
@Test("Every item and every representation round-trips, in order (F425)")
func multiTypeItemsRoundTrip() async throws {
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

    #expect(await dictate("dictated words", with: injector) == .pasted)
    #expect(harness.text == "dictated words")
    harness.scheduler.runAll()

    let after = harness.contents
    #expect(after.map { $0.map(\.type) } == before.map { $0.map(\.type) })
    #expect(after.map { $0.map(\.data) } == before.map { $0.map(\.data) })
}

@MainActor
@Test("An empty clipboard is restored to empty, not left holding the dictation (F425)")
func emptyClipboardRestoresToEmpty() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector()
    harness.board.clearContents()
    try #require(harness.contents.isEmpty)

    #expect(await dictate("dictated words", with: injector) == .pasted)
    #expect(harness.text == "dictated words")
    harness.scheduler.runAll()

    #expect(harness.contents.isEmpty)
}

@MainActor
@Test("A clipboard larger than the cap is not held, so it is not restored (F425)")
func oversizeClipboardIsNotHeld() async throws {
    let harness = try ClipboardHarness()
    let injector = harness.makeInjector(maximumSnapshotBytes: 8)
    harness.put("more than eight bytes")

    #expect(await dictate("dictated words", with: injector) == .pasted)
    harness.scheduler.runAll()

    #expect(harness.text == "dictated words")
}

@MainActor
@Test("A clipboard marked concealed or transient is never copied, so it is not restored (F425)")
func concealedClipboardIsNotHeld() async throws {
    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
        let harness = try ClipboardHarness()
        let injector = harness.makeInjector()
        let item = NSPasteboardItem()
        #expect(item.setString("hunter2", forType: .string))
        #expect(item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)))
        harness.board.clearContents()
        #expect(harness.board.writeObjects([item]))

        #expect(await dictate("dictated words", with: injector) == .pasted)
        harness.scheduler.runAll()

        #expect(harness.text == "dictated words", "marker \(marker)")
    }
}

@MainActor
@Test("A second dictation inside the restore window still ends with the user's clipboard, whichever lands first (F425)")
func rapidSecondDictationRestoresTheOriginal() async throws {
    // Second paste before the first restore fires.
    do {
        let harness = try ClipboardHarness()
        let injector = harness.makeInjector()
        harness.put("copied on my phone")

        #expect(await dictate("first sentence", with: injector) == .pasted)
        #expect(await dictate("second sentence", with: injector) == .pasted)
        #expect(harness.text == "second sentence")
        harness.scheduler.runAll()

        #expect(harness.text == "copied on my phone")
    }
    // First restore fires while the second dictation is still being spoken.
    do {
        let harness = try ClipboardHarness()
        let injector = harness.makeInjector()
        harness.put("copied on my phone")

        #expect(await dictate("first sentence", with: injector) == .pasted)
        injector.captureWillStart(autoPaste: true)
        await injector.snapshotRead?.value
        harness.scheduler.runAll()
        #expect(harness.text == "copied on my phone")
        #expect(injector.deliver("second sentence", autoPaste: true) == .pasted)
        #expect(harness.text == "second sentence")
        harness.scheduler.runAll()

        #expect(harness.text == "copied on my phone")
    }
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
/// capture start and delivery reach the injector. The test touches the injector only to await its
/// snapshot read; every call into it comes from the controller.
@MainActor
@Test("A hotkey dictation with auto-paste on gives the clipboard back after pasting (F425)")
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
    await injector.snapshotRead?.value
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
