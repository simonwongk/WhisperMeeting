import AppKit
import CoreGraphics
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F584 — a trigger changed while a dictation is in flight. The rule the controller follows:
///
/// 1. The trigger it is already running, chosen again, changes nothing mid-dictation (F446).
/// 2. With no capture live — idle, transcribing, or showing its result — the new trigger is armed
///    at once.
/// 3. A toggle key changed to another toggle key while listening takes the dictation over, and the
///    new key's next press turns it off (F446).
/// 4. Any other change while listening ends that dictation the way its own trigger would, so it is
///    transcribed and delivered, and then arms the new trigger.
///
/// These run the real `HotkeyMonitor`'s edge logic, fed real `CGEvent`s through
/// `handle(type:event:)`, the entry the tap callback uses. `FakeHotkeyMonitor` cannot see any of it:
/// every route here is in what the monitor does with the new trigger.

/// Which keys are physically down, as `CGEventSource.keyState` would answer.
private final class Keyboard: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<CGKeyCode> = []
    func isDown(_ key: CGKeyCode) -> Bool { lock.withLock { held.contains(key) } }
    var heldKeys: Set<CGKeyCode> { lock.withLock { held } }
    func set(_ key: CGKeyCode, down: Bool) {
        lock.withLock {
            if down { held.insert(key) } else { held.remove(key) }
        }
    }
}

/// `HotkeyMonitor.start` without its event taps, which need Accessibility and would hear the keyboard
/// of whoever runs the suite. Without them, what is left of `start` is `adopt`, so that is what this
/// calls.
private final class TaplessHotkeyMonitor: HotkeyMonitoring {
    private let monitor: HotkeyMonitor
    private let keyboard: Keyboard
    /// Every trigger `start` was asked to arm, in order.
    private(set) var armed: [DictationHotkey] = []

    init(hotkey: DictationHotkey, keyboard: Keyboard) {
        self.keyboard = keyboard
        monitor = HotkeyMonitor(hotkey: hotkey, currentKeyState: { keyboard.isDown($0) })
    }

    var onPressStart: (() -> Void)? {
        get { monitor.onPressStart }
        set { monitor.onPressStart = newValue }
    }
    var onPressEnd: (() -> Void)? {
        get { monitor.onPressEnd }
        set { monitor.onPressEnd = newValue }
    }
    var onPressCancel: (() -> Void)? {
        get { monitor.onPressCancel }
        set { monitor.onPressCancel = newValue }
    }

    func start(hotkey: DictationHotkey) -> Bool {
        armed.append(hotkey)
        monitor.adopt(hotkey)
        return true
    }
    func stop() { monitor.stop() }
    func resetToggleState() { monitor.resetToggleState() }

    /// A key going down or up, as the tap delivers it: every key, not only the trigger.
    func key(_ code: CGKeyCode, down: Bool) throws {
        keyboard.set(code, down: down)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        monitor.handle(type: down ? .keyDown : .keyUp, event: event)
    }

    /// A held key's autorepeat: another key-down, with no key-up before it.
    func repeatKey(_ code: CGKeyCode) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        monitor.handle(type: .keyDown, event: event)
    }

    /// One side's modifier going down or up: a `flagsChanged` whose flags carry the device bit of
    /// every modifier then held, which is how the monitor tells the sides apart.
    func modifier(_ code: CGKeyCode, down: Bool) throws {
        keyboard.set(code, down: down)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.type = .flagsChanged
        var flags: UInt64 = 0
        for held in keyboard.heldKeys {
            switch held {
            case leftCommand: flags |= CGEventFlags.maskCommand.rawValue | 0x0000_0008
            case rightOption: flags |= CGEventFlags.maskAlternate.rawValue | 0x0000_0040
            default: break
            }
        }
        event.flags = CGEventFlags(rawValue: flags)
        monitor.handle(type: .flagsChanged, event: event)
    }

    /// A key coming up that the tap never delivers: the release was still queued on the old tap's
    /// port when a re-arm invalidated it (F636).
    func releaseUnheard(_ code: CGKeyCode) {
        keyboard.set(code, down: false)
    }

    func click() throws {
        let event = try #require(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: .zero, mouseButton: .left
        ))
        monitor.handle(type: .leftMouseDown, event: event)
    }
}

/// The monitor dispatches every edge with `DispatchQueue.main.async`; FIFO, so this runs after them.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private let f5: CGKeyCode = 96
private let f6: CGKeyCode = 97
private let leftCommand: CGKeyCode = 55
private let rightOption: CGKeyCode = 61
private let tab: CGKeyCode = 48
private let kKey: CGKeyCode = 40

private let f5Hold = DictationHotkey(keyCode: f5, mode: .hold)
private let f5Toggle = DictationHotkey(keyCode: f5, mode: .toggle)
private let f6Hold = DictationHotkey(keyCode: f6, mode: .hold)
private let f6Toggle = DictationHotkey(keyCode: f6, mode: .toggle)

/// The frontmost app as F445's check sees it, and a private pasteboard standing in for the clipboard.
@MainActor
private final class Frontmost {
    let board = NSPasteboard.withUniqueName()
    var probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100)
    private(set) var pasteCount = 0

    func injector() -> TextInjector {
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

    deinit { board.releaseGlobally() }
}

@MainActor
private final class PhaseLog: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: TaplessHotkeyMonitor
    let recorder: FakeDictationRecorder
    let overlay: PhaseLog
    let frontmost: Frontmost
    let cleanUp: () -> Void

    /// `clipSeconds` of 1 is long enough to be transcribed; 0.1 is discarded as a tap, which ends a
    /// dictation without a transcription task left running after the test.
    init(
        hotkey: DictationHotkey,
        clipSeconds: TimeInterval = 0.1,
        autoPaste: Bool = false,
        enabled: Bool = true
    ) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyChangeMidDictationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(enabled, forKey: "dictationEnabled")
        defaults.set(autoPaste, forKey: "dictationAutoPaste")
        defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")

        let monitor = TaplessHotkeyMonitor(hotkey: hotkey, keyboard: Keyboard())
        let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        recorder.stopDuration = clipSeconds
        let overlay = PhaseLog()
        let frontmost = Frontmost()
        self.monitor = monitor
        self.recorder = recorder
        self.overlay = overlay
        self.frontmost = frontmost
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: recorder,
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            // Never fires inside a test: every capture here must end on a key or a change.
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: frontmost.injector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
    }

    /// Waits for the transcription a capture was handed to. The polled status is the subject — the
    /// dictation was delivered — and an exhausted budget fails as the wait it is.
    func waitForDelivery() async throws {
        for _ in 0..<2_000 where controller.status == .transcribing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(controller.status == .delivering, "the dictation was not delivered: \(controller.status)")
    }
}

// MARK: - Rule 4: a change under a live capture ends it, then arms

/// Settings ▸ Change sets the new trigger on that key's own key-DOWN, so it is held when armed. On
/// main before F584 the monitor then read it as down and its RELEASE ended the dictation F5 was
/// holding, later than the change. Now the change itself ends it, through the same finish a release
/// takes, so the audio is transcribed and delivered, and F445 still judges the paste against the
/// app F5 was pressed in.
@MainActor
@Test("A hold trigger changed mid-dictation ends that dictation at once, and it is delivered (F584)")
func holdTriggerChangedMidDictationEndsAndDeliversIt() async throws {
    let harness = try Harness(hotkey: f5Hold, clipSeconds: 1, autoPaste: true)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)            // pressed in app 100
    await drainMainQueue()
    try #require(controller.status == .listening)

    // Still holding F5, the user is in Settings, another app, and presses Change, then F6. The tap
    // hears F6 go down first; Settings then sets it.
    harness.frontmost.probe = FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 200)
    try monitor.key(f6, down: true)
    controller.hotkey = f6Hold
    #expect(recorder.stopCount == 1, "the change did not end the dictation F5 was holding")
    #expect(!recorder.isRecording)
    #expect(controller.status == .transcribing, "the dictation was not handed to transcription")
    #expect(monitor.armed.last == f6Hold)

    // F6's press started nothing, so neither its repeat nor its release does anything, and F5's
    // release is no longer a trigger's.
    try monitor.repeatKey(f6)
    try monitor.key(f6, down: false)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    #expect(recorder.stopCount == 1)
    #expect(!recorder.isRecording)

    try await harness.waitForDelivery()
    #expect(harness.frontmost.pasteCount == 0, "pasted into Settings, not the app F5 was pressed in")
    #expect(harness.frontmost.text == "dictated words")
    #expect(harness.overlay.phases.last == .appChanged)
    let entry = try #require(controller.logStore.log.entries.first)
    #expect(entry.text == "dictated words")
    #expect(entry.outcome == .clipboard)

    // F6 is the trigger now and F5 is not.
    recorder.stopDuration = 0.1
    try monitor.key(f5, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F5 still starts a dictation after F6 was chosen")
    try monitor.key(f5, down: false)
    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(recorder.isRecording, "F6 does not start a dictation")
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.stopCount == 2)
    #expect(!recorder.isRecording)
}

/// The Trigger-mode picker, toggle to hold, while toggle dictation is on. Adopting hold cleared the
/// on-state and hold waits for a release that was made before the change, so on main the capture
/// ran until the key was pressed and released again, or the watchdog.
@MainActor
@Test("Switching a toggle dictation's trigger to Hold ends that dictation at once (F584)")
func toggleSwitchedToHoldEndsTheDictationAtOnce() async throws {
    let harness = try Harness(hotkey: f5Toggle, clipSeconds: 1)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    try #require(controller.status == .listening)

    controller.hotkey = f5Hold
    #expect(recorder.stopCount == 1, "switching to Hold left the toggle dictation listening")
    #expect(!recorder.isRecording)
    #expect(controller.status == .transcribing)
    #expect(monitor.armed.last == f5Hold)

    try await harness.waitForDelivery()
    #expect(controller.logStore.log.entries.first?.text == "dictated words")

    // Hold is in effect: a press starts, its release ends.
    recorder.stopDuration = 0.1
    try monitor.key(f5, down: true)
    await drainMainQueue()
    #expect(recorder.isRecording, "hold mode did not start on a press")
    try monitor.key(f5, down: false)
    await drainMainQueue()
    #expect(!recorder.isRecording, "hold mode did not end on the release")
    #expect(recorder.stopCount == 2)
}

/// The ticket's watchdog route: the picker switched from hold to toggle while the F-key is held.
/// Toggle ignores releases and its on-state had been cleared, so on main no press of the trigger
/// could end the capture, and the 120 s watchdog did.
@MainActor
@Test("Switching a held dictation's trigger to Toggle ends that dictation at once (F584)")
func holdSwitchedToToggleEndsTheDictationAtOnce() async throws {
    let harness = try Harness(hotkey: f5Hold, clipSeconds: 1)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)
    await drainMainQueue()
    try #require(controller.status == .listening)

    controller.hotkey = f5Toggle              // F5 still held
    #expect(recorder.stopCount == 1, "switching to Toggle left the held dictation listening")
    #expect(!recorder.isRecording)
    #expect(controller.status == .transcribing)
    #expect(monitor.armed.last == f5Toggle)

    // Still the same hold: its repeat is no new press, and toggle acts on presses only.
    try monitor.repeatKey(f5)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    #expect(!recorder.isRecording, "a capture is live after the held key's repeat and release")
    #expect(recorder.stopCount == 1)

    try await harness.waitForDelivery()

    // Toggle is in effect: a press starts, the next press ends.
    recorder.stopDuration = 0.1
    try monitor.key(f5, down: true)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    #expect(recorder.isRecording, "toggle mode did not start on a press")
    try monitor.key(f5, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "toggle mode did not end on the next press")
    #expect(recorder.stopCount == 2)
}

/// The two-step strand 8c05658 left: toggle on → Hold (deferred there) → Change → F6. Settings then
/// said "Hold / F6" while F5 toggle was armed, and only F5 or the watchdog ended the dictation.
@MainActor
@Test("Toggle → Hold → another key strands nothing, and the key chosen last is the trigger (F584)")
func modeThenKeyChangeStrandsNothing() async throws {
    let harness = try Harness(hotkey: f5Toggle, clipSeconds: 1)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    try #require(controller.status == .listening)

    controller.hotkey = f5Hold                 // the Trigger picker
    #expect(!recorder.isRecording, "switching to Hold left the toggle dictation listening")

    try monitor.key(f6, down: true)            // Change, then F6, while that dictation transcribes
    controller.hotkey = f6Hold
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.stopCount == 1)
    #expect(!recorder.isRecording)
    #expect(monitor.armed.last == f6Hold, "Settings shows Hold / F6 but \(String(describing: monitor.armed.last)) is armed")

    try await harness.waitForDelivery()
    recorder.stopDuration = 0.1
    try monitor.key(f5, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F5 still starts a dictation")
    try monitor.key(f5, down: false)
    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(recorder.isRecording, "F6 does not start a dictation")
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F6's release did not end its dictation")
    #expect(recorder.stopCount == 2)
}

// MARK: - Rule 3: toggle to toggle takes over

/// F446's design, which 93cd8f0's deferral broke: the on-state belongs to the dictation, so the NEW
/// key's next press turns it off. The new key is held when it is armed, and a held key can repeat
/// its key-down; read as up, that repeat would be a press, and turn the dictation off early.
@MainActor
@Test("A toggle key changed to another toggle key keeps the dictation on until the new key's press (F584)")
func toggleKeyChangedMidDictationEndsOnTheNewKeysPress() async throws {
    let harness = try Harness(hotkey: f5Toggle)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    try #require(controller.status == .listening)

    try monitor.key(f6, down: true)            // Change, then F6
    controller.hotkey = f6Toggle
    try monitor.repeatKey(f6)
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(monitor.armed.last == f6Toggle)
    // Re-armed under a live dictation, which still owns `status` (F446).
    #expect(controller.status == .listening)
    #expect(controller.isActive)
    #expect(recorder.isRecording)
    #expect(recorder.stopCount == 0)

    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(recorder.stopCount == 1, "F6's press did not end the dictation")
    #expect(!recorder.isRecording)
}

/// Toggle to toggle onto a MODIFIER that is held when it is armed. Its key-down was never this
/// monitor's press, so it started no dictation — but on main the monitor treated the hold as the
/// dictation's, and ⌘-Tab or a click during it was F448's shortcut cancel: the dictation Right ⌥ had
/// turned on was dropped unheard.
@MainActor
@Test("A modifier chosen mid-toggle-dictation does not cancel that dictation when used in a shortcut (F584)")
func heldModifierChosenMidToggleDictationCancelsNothing() async throws {
    let harness = try Harness(hotkey: DictationHotkey(keyCode: rightOption, mode: .toggle))
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.modifier(rightOption, down: true)
    try monitor.modifier(rightOption, down: false)
    await drainMainQueue()
    try #require(controller.status == .listening)

    try monitor.modifier(leftCommand, down: true)   // Change, then Left ⌘
    controller.hotkey = DictationHotkey(keyCode: leftCommand, mode: .toggle)
    try monitor.key(tab, down: true)                // ⌘-Tab, still holding ⌘
    try monitor.key(tab, down: false)
    try monitor.click()
    await drainMainQueue()
    #expect(recorder.isRecording, "⌘-Tab on the newly chosen key dropped the dictation Right ⌥ turned on")
    #expect(controller.status == .listening)
    #expect(recorder.stopCount == 0)

    // Left ⌘'s next press ends it, normally: stopped for transcription, not cancelled.
    try monitor.modifier(leftCommand, down: false)
    try monitor.modifier(leftCommand, down: true)
    await drainMainQueue()
    #expect(recorder.stopCount == 1, "Left ⌘'s press did not end the dictation")
    #expect(!recorder.isRecording)
}

// MARK: - Rule 2: no capture live, armed at once

/// 93cd8f0 and 8c05658 deferred a change made over the result pill, so the old trigger carried into
/// the next dictation — F443 lets a press there start one straight away.
@MainActor
@Test("A trigger chosen while the result pill shows is armed at once, and the next press uses it (F584)")
func triggerChosenOverTheResultPillIsArmedAtOnce() async throws {
    let harness = try Harness(hotkey: f5Hold, clipSeconds: 1)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)
    await drainMainQueue()
    try monitor.key(f5, down: false)
    await drainMainQueue()
    try await harness.waitForDelivery()

    try monitor.key(f6, down: true)            // Change, then F6, over the pill
    controller.hotkey = f6Hold
    #expect(monitor.armed.last == f6Hold, "a trigger chosen over the result pill was not armed")
    #expect(controller.status == .delivering, "arming wrote over the status of the dictation on screen")
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.stopCount == 1)

    recorder.stopDuration = 0.1
    try monitor.key(f5, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F5 still starts a dictation")
    try monitor.key(f5, down: false)
    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(recorder.isRecording, "F6 does not start a dictation")
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.stopCount == 2)
    #expect(!recorder.isRecording)
}

// MARK: - A start heard for a trigger that is no longer armed

/// An edge reaches the controller one main-queue turn after the tap heard it, and the trigger can be
/// re-armed in between. A hold start delivered after that began a dictation whose release comes
/// from a key the monitor no longer hears.
@MainActor
@Test("A press of the old trigger delivered after a new one is armed starts nothing (F584)")
func staleHoldStartIsDropped() async throws {
    let harness = try Harness(hotkey: f5Hold)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)            // heard; its start is still queued
    controller.hotkey = f6Hold                 // idle, so armed at once
    await drainMainQueue()
    #expect(!recorder.isRecording, "F5's press started a dictation F5's release can no longer end")
    #expect(controller.status == .idle)

    try monitor.key(f5, down: false)
    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(recorder.isRecording, "F6 does not start a dictation")
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(!recorder.isRecording)
    #expect(recorder.stopCount == 1)
}

/// The drop undoes only the on-state its own press set. Here the new key is pressed twice before any
/// of the queued edges is delivered — off, then on — so the on-state is F6's by then, and a blind
/// reset would leave F6's dictation on with the monitor believing it off: every later F6 press a
/// refused start, and no press of F6 to end it.
@MainActor
@Test("A dropped toggle start leaves an on-state a later press set alone (F584)")
func staleToggleStartLeavesALaterPressesOnState() async throws {
    let harness = try Harness(hotkey: f5Toggle)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)            // on: a start for F5, queued
    try monitor.key(f5, down: false)
    controller.hotkey = f6Toggle               // idle, so armed at once
    try monitor.key(f6, down: true)            // off: an end, queued
    try monitor.key(f6, down: false)
    try monitor.key(f6, down: true)            // on: a start for F6, queued
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.isRecording, "F6's second press did not start a dictation")
    #expect(recorder.stopCount == 0, "F5's stale press started a dictation")
    #expect(controller.status == .listening)

    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F6's next press did not end the dictation it started")
    #expect(recorder.stopCount == 1)
}

// MARK: - Rule 1 and F448 together

/// Settings' Change hears the trigger itself. When it re-arms Right ⌥ before that press's start is
/// delivered, the press is still this monitor's own and the dictation it starts is still a shortcut
/// candidate: ⌥K is a character, not a dictation (F448). Guards `adopt`'s held-key rule against
/// reaching a key whose press the monitor heard.
@MainActor
@Test("Re-choosing a held modifier trigger keeps F448's shortcut cancel for the dictation it starts (F584)")
func rechoosingAHeldModifierKeepsTheShortcutCancel() async throws {
    let rightOptionHold = DictationHotkey(keyCode: rightOption, mode: .hold)
    let harness = try Harness(hotkey: rightOptionHold)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.modifier(rightOption, down: true)   // heard; its start is still queued
    controller.hotkey = rightOptionHold              // idle, so the same trigger re-taps
    await drainMainQueue()
    try #require(recorder.isRecording, "the re-chosen trigger's own press did not start a dictation")

    try monitor.key(kKey, down: true)               // ⌥K
    await drainMainQueue()
    #expect(!recorder.isRecording, "⌥K was not cancelled as a shortcut")
    #expect(recorder.stopCount == 0)
    #expect(controller.status == .idle)
}

// MARK: - What a change is judged against

/// Rules 3 and 4 are decided against the trigger the monitor is running. One chosen while dictation
/// is off is not armed until it is turned on, and turning it on must make it the one judged: judged
/// against the stale hold trigger instead, this toggle-to-toggle change would end the dictation.
@MainActor
@Test("A trigger chosen while dictation is off is what a later mid-dictation change is judged against (F584)")
func triggerChosenWhileOffIsJudgedAfterEnabling() async throws {
    let harness = try Harness(hotkey: f5Hold, enabled: false)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    controller.hotkey = f5Toggle
    #expect(monitor.armed.isEmpty, "a trigger was armed while dictation was off")
    controller.setEnabled(true)
    #expect(monitor.armed.last == f5Toggle)

    try monitor.key(f5, down: true)
    try monitor.key(f5, down: false)
    await drainMainQueue()
    try #require(controller.status == .listening)

    try monitor.key(f6, down: true)
    controller.hotkey = f6Toggle
    try monitor.key(f6, down: false)
    await drainMainQueue()
    #expect(recorder.isRecording, "the toggle-to-toggle change ended the dictation")
    #expect(controller.status == .listening)
    try monitor.key(f6, down: true)
    await drainMainQueue()
    #expect(!recorder.isRecording, "F6's press did not end the dictation")
    #expect(recorder.stopCount == 1)
}

// MARK: - The same trigger re-armed while idle (F636, F446)

/// F636, the reviewer's trace: hold mode, idle, Settings ▸ Change, then a quick tap of the trigger
/// while the main thread is busy. The old tap hears the key go down and queues a start; Change
/// re-arms the same trigger before that start is delivered, and invalidating the old tap loses its
/// release. The start was still delivered, so the dictation listened until the key was pressed and
/// released again or the watchdog.
@MainActor
@Test("A quick tap whose release is lost while Change re-arms the same trigger does not leave the mic on (F636)")
func aReleaseLostWhileTheSameTriggerIsRearmedEndsTheDictation() async throws {
    let harness = try Harness(hotkey: f5Hold)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    try monitor.key(f5, down: true)   // heard; its start is still on the main queue
    monitor.releaseUnheard(f5)        // released while the old tap is being replaced
    controller.hotkey = f5Hold        // Change heard F5 and chose it again
    #expect(monitor.armed.last == f5Hold, "an idle re-choice did not re-arm")
    await drainMainQueue()

    #expect(!recorder.isRecording, "the dictation the quick tap started is still listening")
    #expect(recorder.stopCount == 1)
    #expect(controller.status != .listening)
}

/// F446's hold-mode case at the controller, through the real monitor (F636 part 2; F584 left only
/// the toggle version). Settings' Change hears the trigger key itself, so re-choosing the key you
/// are holding happens mid-press — before the start is delivered, and after.
@MainActor
@Test("Re-choosing the hold trigger you are holding keeps its dictation until you let go (F636, F446)")
func rechoosingTheHeldHoldTriggerKeepsItsDictation() async throws {
    let harness = try Harness(hotkey: f5Hold)
    defer { harness.cleanUp() }
    let (controller, monitor, recorder) = (harness.controller, harness.monitor, harness.recorder)

    // Chosen while its start is still queued: idle, so it re-arms, and the held key is kept.
    try monitor.key(f5, down: true)
    controller.hotkey = f5Hold
    await drainMainQueue()
    try #require(controller.status == .listening, "re-arming under the queued start lost it")
    let armsWhileListening = monitor.armed.count

    // Chosen again while that dictation listens: nothing is re-armed under it.
    try monitor.repeatKey(f5)
    controller.hotkey = f5Hold
    #expect(monitor.armed.count == armsWhileListening, "the tap was rebuilt under a live dictation")
    #expect(controller.status == .listening)

    try monitor.key(f5, down: false)
    await drainMainQueue()
    #expect(!recorder.isRecording, "letting go of F5 did not end the dictation")
    #expect(recorder.stopCount == 1)
}
