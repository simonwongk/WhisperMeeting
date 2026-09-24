import CoreGraphics
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F448 — a modifier trigger is also half of every shortcut that uses it: ⌘-Tab, ⌥-click, ⌥⇧→, the
/// characters Right ⌥ types on most layouts. The monitor used to ignore every event but the trigger's
/// own, so holding the modifier for a shortcut started the microphone, and a hold of 0.35 s or more
/// was transcribed and pasted. These feed real `CGEvent`s through `HotkeyMonitor.handle`, the same
/// entry the tap callback uses, without creating a tap.

private final class Edges: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (starts: 0, ends: 0, cancels: 0)
    func start() { lock.withLock { counts.starts += 1 } }
    func end() { lock.withLock { counts.ends += 1 } }
    func cancel() { lock.withLock { counts.cancels += 1 } }
    var starts: Int { lock.withLock { counts.starts } }
    var ends: Int { lock.withLock { counts.ends } }
    var cancels: Int { lock.withLock { counts.cancels } }
}

/// The monitor dispatches with `DispatchQueue.main.async`; FIFO, so this runs after them.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// A `flagsChanged` for one side's modifier key, carrying the device bit that says which side is down.
private func modifier(_ keyCode: CGKeyCode, down: Bool) throws -> CGEvent {
    let (deviceBit, flag): (UInt64, CGEventFlags) = switch keyCode {
    case 55: (0x0000_0008, .maskCommand)    // left ⌘
    case 61: (0x0000_0040, .maskAlternate)  // right ⌥
    default: (0, [])
    }
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
    event.type = .flagsChanged
    event.flags = down ? CGEventFlags(rawValue: flag.rawValue | deviceBit) : []
    return event
}

private func key(_ keyCode: CGKeyCode, down: Bool = true) throws -> CGEvent {
    try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
}

private func click() throws -> CGEvent {
    try #require(CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: .zero, mouseButton: .left
    ))
}

private func wire(_ monitor: HotkeyMonitor, to edges: Edges) {
    monitor.onPressStart = edges.start
    monitor.onPressEnd = edges.end
    monitor.onPressCancel = edges.cancel
}

@MainActor
@Test("A key pressed while a modifier trigger is held cancels the press, once (F448)")
func keyDuringModifierTriggerCancels() async throws {
    let edges = Edges()
    let monitor = HotkeyMonitor(hotkey: DictationHotkey(keyCode: 55, mode: .hold), currentKeyState: { _ in false })
    wire(monitor, to: edges)

    monitor.handle(type: .flagsChanged, event: try modifier(55, down: true))
    monitor.handle(type: .keyDown, event: try key(48))           // ⌘-Tab
    monitor.handle(type: .keyDown, event: try key(48))           // …and Tab again, still holding ⌘
    monitor.handle(type: .flagsChanged, event: try modifier(55, down: false))
    await drainMainQueue()

    #expect(edges.starts == 1)
    #expect(edges.cancels == 1)
    #expect(edges.ends == 1)
}

@MainActor
@Test("A click while a modifier trigger is held cancels the press (F448)")
func clickDuringModifierTriggerCancels() async throws {
    let edges = Edges()
    let monitor = HotkeyMonitor(hotkey: .rightOption, currentKeyState: { _ in false })
    wire(monitor, to: edges)

    monitor.handle(type: .flagsChanged, event: try modifier(61, down: true))
    monitor.handle(type: .leftMouseDown, event: try click())     // ⌥-click
    await drainMainQueue()

    #expect(edges.starts == 1)
    #expect(edges.cancels == 1)
}

@MainActor
@Test("Typing with the trigger up, or beside an F-key trigger, cancels nothing (F448)")
func otherInputOutsideAModifierHoldCancelsNothing() async throws {
    let edges = Edges()
    let modifierTrigger = HotkeyMonitor(hotkey: .rightOption, currentKeyState: { _ in false })
    wire(modifierTrigger, to: edges)
    modifierTrigger.handle(type: .keyDown, event: try key(40))
    modifierTrigger.handle(type: .leftMouseDown, event: try click())

    // An F-key forms no shortcuts, so a key typed while one is held is not a chord.
    let fKeyTrigger = HotkeyMonitor(hotkey: DictationHotkey(keyCode: 96, mode: .hold), currentKeyState: { _ in false })
    wire(fKeyTrigger, to: edges)
    fKeyTrigger.handle(type: .keyDown, event: try key(96))
    fKeyTrigger.handle(type: .keyDown, event: try key(40))
    await drainMainQueue()

    #expect(edges.starts == 1)
    #expect(edges.cancels == 0)
}

// MARK: - Through the controller

@MainActor
private struct ChordHarness {
    let monitor: HotkeyMonitor
    let controller: DictationController
    let recorder: FakeDictationRecorder
    let engine: WarmUpCountingEngine
    let cleanup: () -> Void

    init(mode: DictationHotkey.Mode) throws {
        let suite = "WhisperMeet.HotkeyChordTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyChordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        monitor = HotkeyMonitor(hotkey: DictationHotkey(keyCode: 61, mode: mode), currentKeyState: { _ in false })
        recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        engine = WarmUpCountingEngine()
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: recorder,
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func send(_ type: CGEventType, _ event: CGEvent) async {
        monitor.handle(type: type, event: event)
        await drainMainQueue()
    }
}

@MainActor
@Test("A shortcut on the hold trigger ends its dictation with nothing transcribed or pasted (F448)")
func shortcutOnHoldTriggerDiscardsTheCapture() async throws {
    let harness = try ChordHarness(mode: .hold)
    defer { harness.cleanup() }

    await harness.send(.flagsChanged, try modifier(61, down: true))
    try #require(harness.recorder.isRecording, "holding the trigger did not start a capture")

    await harness.send(.keyDown, try key(40)) // ⌥K: a character on most layouts, not dictation
    #expect(!harness.recorder.isRecording)
    #expect(harness.controller.status == .idle)

    await harness.send(.flagsChanged, try modifier(61, down: false))
    // The release finds no capture to finish: nothing was stopped for transcription.
    #expect(harness.recorder.stopCount == 0)
    #expect(harness.engine.transcribeCount == 0)
    #expect(harness.controller.logStore.log.entries.isEmpty)
}

@MainActor
@Test("A shortcut on the toggle trigger cancels, and the next press starts afresh (F448)")
func shortcutOnToggleTriggerResetsTheToggle() async throws {
    let harness = try ChordHarness(mode: .toggle)
    defer { harness.cleanup() }

    await harness.send(.flagsChanged, try modifier(61, down: true))
    try #require(harness.recorder.isRecording)
    await harness.send(.leftMouseDown, try click())
    await harness.send(.flagsChanged, try modifier(61, down: false))
    #expect(!harness.recorder.isRecording)

    // Toggle mode had latched "on" at that press. Unless the cancel clears it, this press is read as
    // "off" and finishes nothing, instead of starting the dictation the user asked for.
    await harness.send(.flagsChanged, try modifier(61, down: true))
    #expect(harness.recorder.isRecording)
    #expect(harness.controller.status == .listening)
}
