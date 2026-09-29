import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F656 — `TextInjector.deliver` judges secure input and the app in front, and only then may spend
/// seconds on the clipboard: a paste-time read (a lazily provided 12-megapixel image took 2.5 s,
/// F601) or waiting for an early read still in flight (F657). Nothing looked again before ⌘V, so a
/// password prompt — a sudo sheet, a login dialog — that took focus in that window received the
/// dictation, and the history recorded it.
///
/// The probe here reads a flag that the fake clipboard read sets, so the world changes exactly
/// between the judgement and the keystroke. Private pasteboards and a counter for ⌘V.

private final class World: @unchecked Sendable {
    private let lock = NSLock()
    private var _secure = false
    private var _frontmost: pid_t = 100
    private var _reads = 0
    var secure: Bool { lock.withLock { _secure } }
    var frontmost: pid_t { lock.withLock { _frontmost } }
    func passwordPromptTakesFocus() { lock.withLock { _secure = true } }
    func userSwitchesTo(_ pid: pid_t) { lock.withLock { _frontmost = pid } }
    /// Counts clipboard reads, so a change can be tied to the paste-time one.
    func countRead() -> Int { lock.withLock { _reads += 1; return _reads } }
}

@MainActor
private final class RecheckHarness {
    let board = NSPasteboard.withUniqueName()
    let world = World()
    private(set) var pasteCount = 0

    init() throws {
        board.clearContents()
        board.setString("copied on my phone", forType: .string)
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    /// `duringRead` runs inside the clipboard read numbered `onRead` (1 is the first).
    func makeInjector(onRead: Int = 1, duringRead: @escaping @Sendable (World) -> Void) -> TextInjector {
        let world = self.world
        return TextInjector(
            pasteboard: board,
            readSnapshot: { handle, limit in
                if world.countRead() == onRead { duringRead(world) }
                return PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
            },
            canSynthesizePaste: { true },
            focusedTextField: {
                FocusedTextField.Probe(
                    isTextField: true, summary: "test", processIdentifier: world.frontmost,
                    secureInput: world.secure ? .passwordField : nil
                )
            },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { _, _ in }
        )
    }

    deinit { board.releaseGlobally() }
}

@MainActor
@Test("A password prompt that takes focus during the clipboard read gets nothing: no ⌘V, no write (F656)")
func aPasswordPromptDuringTheReadIsNotPastedInto() throws {
    let harness = try RecheckHarness()
    let injector = harness.makeInjector { $0.passwordPromptTakesFocus() }
    let pressedIn = injector.target()
    let before = harness.board.changeCount

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .secureInput)
    #expect(harness.pasteCount == 0)
    #expect(harness.board.changeCount == before)
    #expect(harness.board.string(forType: .string) == "copied on my phone")
}

@MainActor
@Test("Another app brought to the front during the clipboard read is not pasted into (F656)")
func anAppSwitchDuringTheReadIsNotPastedInto() throws {
    let harness = try RecheckHarness()
    let injector = harness.makeInjector { $0.userSwitchesTo(200) }
    let pressedIn = injector.target()

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .appChanged)
    #expect(harness.pasteCount == 0)
    #expect(harness.board.string(forType: .string) == "dictated words")
}

@MainActor
@Test("Nothing changing during the read still pastes (F656)")
func anUnchangedWorldStillPastes() throws {
    let harness = try RecheckHarness()
    let injector = harness.makeInjector { _ in }
    let pressedIn = injector.target()

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    #expect(harness.pasteCount == 1)
}

// MARK: - Through the controller

@MainActor
private final class RecheckOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    var onCopy: (() -> Void)?
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

/// The reachable path: a hotkey dictation whose paste-time read sees a password prompt take focus
/// ends in F586's pill — held for Copy, nowhere else — rather than a paste.
@MainActor
@Test("A hotkey dictation whose target turns secure during the read ends in the secure pill, held for Copy (F656)")
func aHotkeyDictationThatTurnsSecureEndsInTheSecurePill() async throws {
    let harness = try RecheckHarness()
    // The press starts the early read (read 1). Something is copied while the user speaks, so that
    // read is stale and delivery reads again (read 2) — which is when the prompt takes focus.
    let injector = harness.makeInjector(onRead: 2) { $0.passwordPromptTakesFocus() }
    let suite = "WhisperMeet.SecureInputRecheckTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecureInputRecheckTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let overlay = RecheckOverlay()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "dictated words"),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: overlay,
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: injector,
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    monitor.onPressStart?()
    let early = try #require(injector.clipboardPrefetch, "the press did not start the early read")
    await early.value
    harness.board.clearContents()
    harness.board.setString("copied while dictating", forType: .string)
    let before = harness.board.changeCount
    monitor.onPressEnd?()
    let deadline = Date().addingTimeInterval(30)
    while !overlay.phases.contains(where: \.offersCopy), !overlay.phases.contains(.done), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(overlay.phases.contains(where: { $0.offersCopy || $0 == .done }), "the dictation never delivered")

    #expect(overlay.phases.last == .secureInput)
    #expect(harness.pasteCount == 0)
    #expect(harness.board.changeCount == before)
    #expect(controller.heldSecureDictation == "dictated words")
    #expect(controller.logStore.log.entries.isEmpty)
}
