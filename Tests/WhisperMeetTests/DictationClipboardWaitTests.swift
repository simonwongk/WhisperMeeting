import AppKit
import Foundation
import Testing
@testable import WhisperMeet

// F692 — the user's decision of 2026-10-16 ("Paste late, without freezing"). A clipboard owner that
// never answers held the clipboard read for up to 120 s, and the main thread waited on that read at
// paste time (F657's `snapshotQueue.sync`), so the app and the pill froze. Delivery now waits off
// the main thread, the pill says it is waiting for the clipboard, and the paste happens when the
// read returns, through F656's second look. No new history outcome.
//
// The clipboard read here is a fake that blocks until this test releases it — and the test can only
// release it from the main actor, after it has seen the waiting pill. While the main thread is held
// by a frozen delivery it cannot see anything, so the fake gives up by itself after 30 s (the cap,
// not a timing assumption) and the test then fails on what it never saw.

private final class HeldClipboardRead: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var reads = 0
    let release = DispatchSemaphore(value: 0)

    var hasEntered: Bool { lock.withLock { entered } }
    var readCount: Int { lock.withLock { reads } }

    func read(_ handle: TextInjector.PasteboardHandle, _ limit: Int) -> Result<PasteboardSnapshot, PasteboardSnapshot.Refusal> {
        let first: Bool = lock.withLock {
            reads += 1
            entered = true
            return reads == 1
        }
        if first { _ = release.wait(timeout: .now() + 30) }
        return PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
    }
}

private final class RecordingOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
@Test("A clipboard read that does not answer leaves the app responsive, the pill says so, and the paste lands when it returns (F692)")
func aStuckClipboardReadDoesNotFreezeTheDelivery() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied on my phone", forType: .string)
    let held = HeldClipboardRead()
    var pastes = 0
    let injector = TextInjector(
        pasteboard: board,
        readSnapshot: { held.read($0, $1) },
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
        synthesizePaste: { pastes += 1; return true },
        schedule: { _, _ in }
    )
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F692-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        held.release.signal()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationAutoPaste")
    defaults.set(false, forKey: "dictationRefineEnabled")
    let monitor = FakeHotkeyMonitor()
    let overlay = RecordingOverlay()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "dictated words"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: overlay,
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: injector,
        activateOnInit: false
    )
    controller.gpuUtilization = { nil }
    controller.clipboardNotifier = {}

    // The press starts the early clipboard read (F601), and it does not come back.
    monitor.onPressStart?()
    try #require(controller.status == .listening)
    let started = ContinuousClock.now + .seconds(30)
    while !held.hasEntered, ContinuousClock.now < started {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(held.hasEntered, "the press did not start the clipboard read")
    monitor.onPressEnd?()

    // This loop runs on the main actor: it can only see the pill while the main thread is free.
    let deadline = ContinuousClock.now + .seconds(30)
    while !overlay.phases.contains(.waitingForClipboard), controller.logStore.log.entries.isEmpty,
          ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(overlay.phases.contains(.waitingForClipboard),
                 "the pill never said it was waiting for the clipboard (phases: \(overlay.phases))")
    #expect(controller.logStore.log.entries.isEmpty, "delivered before the clipboard read returned")
    #expect(pastes == 0)
    #expect(controller.status == .delivering)

    held.release.signal()
    let landed = ContinuousClock.now + .seconds(30)
    while controller.logStore.log.entries.isEmpty, ContinuousClock.now < landed {
        try await Task.sleep(for: .milliseconds(5))
    }
    let entry = try #require(controller.logStore.log.entries.first, "the dictation never landed")
    #expect(entry.outcome == .pasted)
    #expect(entry.text == "dictated words")
    #expect(pastes == 1)
    #expect(DictationController.announcement(for: .waitingForClipboard) == nil)
}

@MainActor
@Test("The early read that came back is used at paste time, with no second read of the clipboard (F692, F601)")
func anAnsweredEarlyReadIsNotReadAgain() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied on my phone", forType: .string)
    let held = HeldClipboardRead()
    held.release.signal() // answers at once
    let injector = TextInjector(
        pasteboard: board,
        readSnapshot: { held.read($0, $1) },
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
        synthesizePaste: { true },
        schedule: { _, _ in }
    )
    let pressedIn = injector.captureWillStart(autoPaste: true)
    let waited = await injector.prepareDelivery(autoPaste: true)
    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn, waitedForClipboard: waited) == .pasted)
    #expect(held.readCount == 1, "the clipboard was read again at paste time")
}

/// Counts the clipboard reads, answering each at once.
private final class CountingClipboardRead: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func read(_ handle: TextInjector.PasteboardHandle, _ limit: Int) -> Result<PasteboardSnapshot, PasteboardSnapshot.Refusal> {
        lock.withLock { reads += 1 }
        return PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
    }
}

/// The round-2 review's C4: the path F692 exists for, with the paste-time read. The early read
/// answers, then something arrives on the clipboard while the user speaks; `prepareDelivery` must
/// make the paste-time read, off the main thread, and `deliver` must use it rather than read again
/// on the main thread. Mutant M1 (prepareDelivery reads and throws the answer away) survived round 2.
@MainActor
@Test("When the clipboard changed after the early read, prepareDelivery's read is the one deliver uses (F692, the round-2 review's C4)")
func thePasteTimeReadIsMadeOffTheMainThread() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied before the press", forType: .string)
    let reader = CountingClipboardRead()
    let injector = TextInjector(
        pasteboard: board,
        readSnapshot: { reader.read($0, $1) },
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
        synthesizePaste: { true },
        schedule: { _, _ in }
    )
    let pressedIn = injector.captureWillStart(autoPaste: true)
    await injector.clipboardPrefetch?.value
    try #require(reader.readCount == 1)
    // Something arrives on the clipboard while the user speaks (an item from the iPhone).
    board.clearContents()
    board.setString("arrived while speaking", forType: .string)
    let waited = await injector.prepareDelivery(autoPaste: true)
    #expect(waited)
    #expect(reader.readCount == 2, "prepareDelivery did not make the paste-time read")
    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn, waitedForClipboard: waited) == .pasted)
    #expect(reader.readCount == 2, "deliver read the clipboard again, on the main thread")
}

/// The round-2 review's C5: switching dictation off drops a dictation waiting for the clipboard, and
/// switching it back on must not let that dictation paste later into the new session.
@MainActor
@Test("A dictation dropped by switching dictation off while it waits for the clipboard is not pasted after it is switched back on (F692, the round-2 review's C5)")
func aDroppedWaitingDictationIsNotPastedAfterReEnabling() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied on my phone", forType: .string)
    let held = HeldClipboardRead()
    var pastes = 0
    let injector = TextInjector(
        pasteboard: board,
        readSnapshot: { held.read($0, $1) },
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
        synthesizePaste: { pastes += 1; return true },
        schedule: { _, _ in }
    )
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F692-C5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        held.release.signal()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationAutoPaste")
    defaults.set(false, forKey: "dictationRefineEnabled")
    let monitor = FakeHotkeyMonitor()
    let overlay = RecordingOverlay()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "the dropped dictation"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: overlay,
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: injector,
        activateOnInit: false
    )
    controller.gpuUtilization = { nil }
    controller.clipboardNotifier = {}

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    let started = ContinuousClock.now + .seconds(30)
    while !held.hasEntered, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(5)) }
    try #require(held.hasEntered)
    monitor.onPressEnd?()
    let deadline = ContinuousClock.now + .seconds(30)
    while !overlay.phases.contains(.waitingForClipboard), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(overlay.phases.contains(.waitingForClipboard))

    // The user switches dictation off (which drops this dictation) and on again.
    controller.setEnabled(false)
    controller.setEnabled(true)
    let waitingDelivery = try #require(controller.waitingDeliveryForTesting, "no delivery was waiting")

    held.release.signal()
    // The waiting delivery itself is the subject: once it has returned it has pasted or never will.
    await waitingDelivery.value
    #expect(pastes == 0, "the dictation dropped by switching dictation off was pasted after it was switched back on")
    #expect(controller.logStore.log.entries.isEmpty)
}
