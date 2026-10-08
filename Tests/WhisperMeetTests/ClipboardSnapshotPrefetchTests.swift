import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F601, part 2 — F516 read the whole clipboard synchronously on the main actor at paste time, just
/// before writing the transcript and posting ⌘V, with no size limit: every representation of
/// whatever the user had copied, produced on demand if the owner provides it lazily, on the run
/// loop that also hosts the hotkey tap. Measured 2026-09-28 with a 4032 × 3024 image offered by
/// another process as TIFF and PNG: offered lazily, the first read took 2,531 ms (TIFF 104 ms, PNG
/// 2,412 ms) and copied 88.8 MB — about 150 frames at 60 Hz, far past the ticket's "a frame or two";
/// offered eagerly, 22 ms, 1.3 frames, under that threshold though it still copied 88.8 MB. The lazy
/// case decided it: F425's off-main read and 32 MiB cap come back — the read starts when the
/// dictation does, and is used at paste time only while the clipboard is provably the same
/// (`changeCount`), so F516's "the clipboard at paste time" holds.
///
/// Private pasteboards, a counter for ⌘V, a scheduler fired by hand, and a snapshot reader that
/// records which thread it ran on. The one wait is on the read's own task, required to exist.

/// Every snapshot read, and whether it ran on the main thread. Lock-guarded: the prefetch reads on
/// the snapshot queue.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _onMain: [Bool] = []
    var onMain: [Bool] { lock.withLock { _onMain } }
    func record() { lock.withLock { _onMain.append(Thread.isMainThread) } }
}

@MainActor
private final class PrefetchHarness {
    let board = NSPasteboard.withUniqueName()
    let reads = ReadLog()
    private(set) var pasteCount = 0
    private(set) var restores: [@MainActor () -> Void] = []

    init() throws {
        put("copied on my phone")
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector(maximumSnapshotBytes: Int = TextInjector.defaultMaximumSnapshotBytes) -> TextInjector {
        let reads = self.reads
        return TextInjector(
            pasteboard: board,
            maximumSnapshotBytes: maximumSnapshotBytes,
            readSnapshot: { handle, limit in
                reads.record()
                return PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
            },
            canSynthesizePaste: { true },
            focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { [unowned self] _, work in self.restores.append(work) }
        )
    }

    func put(_ string: String) {
        board.clearContents()
        board.setString(string, forType: .string)
    }

    func runRestores() {
        let due = restores
        restores.removeAll()
        for work in due { work() }
    }

    var text: String? { board.string(forType: .string) }

    deinit { board.releaseGlobally() }
}

// MARK: - The cap

@MainActor
@Test("A clipboard over the size cap is not copied, and says why (F601)")
func aClipboardOverTheCapIsRefused() throws {
    let harness = try PrefetchHarness()
    let size = Data("copied on my phone".utf8).count

    guard case .failure(.tooLarge) = PasteboardSnapshot.read(from: harness.board, maximumBytes: size - 1) else {
        Issue.record("a clipboard one byte over the cap was copied")
        return
    }
    guard case let .success(snapshot) = PasteboardSnapshot.read(from: harness.board, maximumBytes: size) else {
        Issue.record("a clipboard exactly at the cap was refused")
        return
    }
    #expect(snapshot.items.count == 1)
}

@MainActor
@Test("A clipboard over the size cap is not given back; the dictation stays on it (F601)")
func aClipboardOverTheCapIsNotRestored() throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector(maximumSnapshotBytes: 8)

    #expect(injector.deliver("dictated words", autoPaste: true) == .pasted)
    #expect(harness.restores.isEmpty)
    #expect(harness.text == "dictated words")
}

// MARK: - The off-main read

@MainActor
@Test("The clipboard is copied off the main thread when the dictation starts, and nothing is read at paste time (F601)")
func theClipboardIsCopiedOffTheMainThread() async throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector()

    let pressedIn = injector.captureWillStart(autoPaste: true)
    let read = try #require(injector.clipboardPrefetch, "the clipboard was not read when the dictation started")
    await read.value
    #expect(harness.reads.onMain == [false])

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    #expect(harness.reads.onMain == [false], "the clipboard was read again, on the paste's thread")
    harness.runRestores()
    #expect(harness.text == "copied on my phone")
}

@MainActor
@Test("Something copied after the early read is what comes back, read at paste time (F601 keeps F516)")
func aClipboardChangedAfterTheEarlyReadIsReadAgain() async throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector()

    let pressedIn = injector.captureWillStart(autoPaste: true)
    let read = try #require(injector.clipboardPrefetch, "the clipboard was not read when the dictation started")
    await read.value
    harness.put("copied on my phone while dictating")

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    // Read again at paste time. Which thread runs it is GCD's choice since F657 routes it through
    // the snapshot queue with `sync` ("invokes the block on the current thread when possible"), so
    // only the early read's thread is asserted.
    #expect(harness.reads.onMain.count == 2)
    #expect(harness.reads.onMain.first == false)
    harness.runRestores()
    #expect(harness.text == "copied on my phone while dictating")
}

@MainActor
@Test("An early read refused for size is not repeated on the main thread at paste time (F601)")
func aRefusedEarlyReadIsNotRepeated() async throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector(maximumSnapshotBytes: 8)

    let pressedIn = injector.captureWillStart(autoPaste: true)
    let read = try #require(injector.clipboardPrefetch, "the clipboard was not read when the dictation started")
    await read.value

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    #expect(harness.reads.onMain == [false])
    #expect(harness.restores.isEmpty)
    #expect(harness.text == "dictated words")
}

@MainActor
@Test("Nothing is read early when the dictation will not be pasted into a text field (F601)")
func nothingIsReadEarlyWithoutAPasteToRestoreAfter() throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector()

    _ = injector.captureWillStart(autoPaste: false)
    #expect(injector.clipboardPrefetch == nil)
    #expect(harness.reads.onMain.isEmpty)
}

/// The reachable path: the hotkey's press starts the early read through a real
/// `DictationController`, and its release pastes and restores from it.
@MainActor
@Test("A hotkey dictation copies the clipboard off the main thread and gives it back (F601)")
func hotkeyDictationCopiesTheClipboardOffTheMainThread() async throws {
    let harness = try PrefetchHarness()
    let injector = harness.makeInjector()
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardSnapshotPrefetchTests-\(UUID().uuidString)")
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

    monitor.onPressStart?()
    let read = try #require(injector.clipboardPrefetch, "the press did not start the clipboard read")
    await read.value
    monitor.onPressEnd?()
    let deadline = Date().addingTimeInterval(30)
    while controller.logStore.log.entries.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let entry = try #require(controller.logStore.log.entries.first, "the dictation was never recorded")

    #expect(entry.outcome == .pasted)
    #expect(harness.reads.onMain == [false])
    #expect(harness.text == "dictated words")
    harness.runRestores()
    #expect(harness.text == "copied on my phone")
}
