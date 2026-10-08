import AppKit
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// Settings ▸ Quick Dictation ▸ Change, through `DictationTriggerChooser`. Its monitors are counted
/// rather than installed — a real one would hear the keyboard and mouse of whoever runs the suite —
/// and the window is a stand-in object, since nothing here draws one. What the chooser feeds the
/// capture from a real `NSEvent` is source-checked in `DictationSettingsSourceTests`.

/// The monitors a chooser installed and removed, by token.
@MainActor
private final class MonitorLedger {
    private(set) var local: [Int] = []
    private(set) var global: [Int] = []
    private(set) var removed: [Int] = []
    private var next = 0

    var live: Set<Int> { Set(local + global).subtracting(removed) }
    var liveGlobal: Set<Int> { Set(global).subtracting(removed) }

    var monitors: DictationTriggerChooser.EventMonitors {
        DictationTriggerChooser.EventMonitors(
            addLocal: { _, _ in self.add(to: \.local) },
            addGlobal: { _, _ in self.add(to: \.global) },
            remove: { self.removed.append($0 as! Int) }
        )
    }

    private func add(to list: ReferenceWritableKeyPath<MonitorLedger, [Int]>) -> Int {
        next += 1
        self[keyPath: list].append(next)
        return next
    }
}

/// A controller with Quick Dictation on and the given trigger, on a fake monitor, with nothing real
/// behind it. Built with `activateOnInit: false` and left so: switching dictation on here would
/// also sync the helpers into the real runtime folder, which nothing in these tests needs. So the
/// fake monitor has not been started when a test begins; the stored setting is what says "on".
@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let recorder: FakeDictationRecorder
    let cleanUp: () -> Void

    init(hotkey: DictationHotkey = DictationHotkey(keyCode: 96, mode: .hold), enabled: Bool = true) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationTriggerChooserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(enabled, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")
        let monitor = FakeHotkeyMonitor()
        let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        self.monitor = monitor
        self.recorder = recorder
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "dictated words"),
            recorder: recorder,
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activationNotifications: NotificationCenter(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        controller.announce = { _ in }
    }
}

private let f5: UInt16 = 96
private let f6: UInt16 = 97
private let rightOption: UInt16 = 61

// MARK: - F691: a choice ends however the user leaves it

/// F691 — the choice ended on Change, a key chosen, Escape and the view going away, but not when
/// WhisperMeet went to the background, so F653's global monitor went on observing, and discarding,
/// every click in every other app until the user came back.
@MainActor
@Test("Choosing a trigger ends when WhisperMeet goes to the background, and both monitors go with it (F691)")
func choosingATriggerEndsInTheBackground() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let ledger = MonitorLedger()
    let notifications = NotificationCenter()
    let chooser = DictationTriggerChooser(monitors: ledger.monitors, notifications: notifications)
    let settingsWindow = NSObject()

    chooser.toggle(in: settingsWindow, for: harness.controller)
    try #require(chooser.isChoosing)
    try #require(ledger.live.count == 2, "choosing installs a local and a global monitor")

    notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(!chooser.isChoosing, "the choice outlived WhisperMeet going to the background")
    #expect(ledger.liveGlobal.isEmpty, "the global monitor still observes clicks in other apps")
    #expect(ledger.live.isEmpty, "a monitor outlived the choice")

    // The observers went with the choice: a later choice is not ended by the first one's window.
    let mainWindow = NSObject()
    chooser.toggle(in: mainWindow, for: harness.controller)
    try #require(chooser.isChoosing)
    notifications.post(name: NSWindow.willCloseNotification, object: settingsWindow)
    #expect(chooser.isChoosing, "an observer from an ended choice ended the next one")
    notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(!chooser.isChoosing)
    #expect(ledger.live.isEmpty)
    #expect(ledger.removed.count == 4, "each monitor is removed exactly once")
}

@MainActor
@Test("Choosing a trigger ends when its window closes, and not when another window does (F691)")
func choosingATriggerEndsWithItsWindow() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let ledger = MonitorLedger()
    let notifications = NotificationCenter()
    let chooser = DictationTriggerChooser(monitors: ledger.monitors, notifications: notifications)
    let settingsWindow = NSObject()

    chooser.toggle(in: settingsWindow, for: harness.controller)
    try #require(chooser.isChoosing)
    notifications.post(name: NSWindow.willCloseNotification, object: NSObject())
    #expect(chooser.isChoosing, "another window closing ended the choice")
    #expect(ledger.live.count == 2)

    notifications.post(name: NSWindow.willCloseNotification, object: settingsWindow)
    #expect(!chooser.isChoosing, "the choice outlived its window")
    #expect(ledger.live.isEmpty, "a monitor outlived the window the choice was made in")
}

@MainActor
@Test("Ending a choice twice removes each monitor once, and Change toggles it off (F691)")
func endingAChoiceIsIdempotent() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let ledger = MonitorLedger()
    let chooser = DictationTriggerChooser(monitors: ledger.monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(!chooser.isChoosing, "Change pressed again did not stop choosing")
    chooser.end()
    chooser.end()
    #expect(ledger.removed.count == 2)
    #expect(ledger.live.isEmpty)
    // No window to choose in: nothing starts.
    chooser.toggle(in: nil, for: harness.controller)
    #expect(!chooser.isChoosing)
    #expect(ledger.local.count == 1)
}

// MARK: - F521's rules, as the chooser carries them out

@MainActor
@Test("An F-key chosen becomes the trigger in the same mode, and the choice ends (F521)")
func anFKeyChosenBecomesTheTrigger() throws {
    let harness = try Harness(hotkey: DictationHotkey(keyCode: rightOption, mode: .toggle))
    defer { harness.cleanUp() }
    let ledger = MonitorLedger()
    let chooser = DictationTriggerChooser(monitors: ledger.monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    let letThrough = chooser.receive(.keyDown(keyCode: f6, isShortcut: false))
    #expect(!letThrough, "the chosen key reached the window")
    #expect(harness.controller.hotkey == DictationHotkey(keyCode: f6, mode: .toggle))
    #expect(!chooser.isChoosing)
    #expect(ledger.live.isEmpty)
}

@MainActor
@Test("Escape cancels a choice and keeps the trigger; a key that cannot be one is refused with a hint (F521)")
func escapeCancelsAndOtherKeysAreRefused() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let ledger = MonitorLedger()
    let chooser = DictationTriggerChooser(monitors: ledger.monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(!chooser.receive(.keyDown(keyCode: 0, isShortcut: false)), "a refused letter typed into the window")
    #expect(chooser.hint == DictationTriggerCapture.refusalHint)
    #expect(chooser.isChoosing)
    // ⌘W is the window's.
    #expect(chooser.receive(.keyDown(keyCode: 13, isShortcut: true)))
    #expect(!chooser.receive(.keyDown(keyCode: DictationKeyName.escapeKeyCode, isShortcut: false)))
    #expect(!chooser.isChoosing)
    #expect(chooser.hint == nil)
    #expect(harness.controller.hotkey == DictationHotkey(keyCode: f5, mode: .hold))
    #expect(ledger.live.isEmpty)
}

@MainActor
@Test("A lone modifier is chosen on its release, which still reaches the window (F521)")
func aLoneModifierIsChosenOnRelease() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())
    let mask = DictationKeyName.modifierDeviceMask(for: rightOption)

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(chooser.receive(.modifiersChanged(keyCode: rightOption, flags: mask)))
    #expect(chooser.receive(.modifiersChanged(keyCode: rightOption, flags: 0)), "the release was kept from the window")
    #expect(harness.controller.hotkey == DictationHotkey(keyCode: rightOption, mode: .hold))
    #expect(!chooser.isChoosing)
}

// MARK: - F683: the trigger is paused while a key is chosen

/// F683 — since F547 an armed F-key trigger is held back from every app, Settings included, so
/// pressing the current trigger in Change started a dictation instead of choosing it again. The
/// fake monitor stands in for the tap: `stop` is the trigger paused, and an `onPressStart` after it
/// is a press the tap heard just before it was let go.
@MainActor
@Test("While a key is chosen the trigger is paused, so its press starts no dictation, and the choice re-arms it (F683)")
func choosingATriggerPausesIt() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(harness.monitor.stopCount == 1, "the trigger stayed armed while a key is chosen")
    #expect(harness.monitor.startCount == 0)
    harness.monitor.onPressStart?()
    #expect(!harness.recorder.isRecording, "a press while choosing started a dictation")
    #expect(harness.controller.status == .idle)

    // The current trigger, pressed in Settings, now reaches the chooser and is chosen again.
    #expect(!chooser.receive(.keyDown(keyCode: f5, isShortcut: false)))
    #expect(!chooser.isChoosing)
    #expect(
        harness.monitor.startedHotkeys == [DictationHotkey(keyCode: f5, mode: .hold)],
        "the choice did not re-arm the trigger, or armed it twice"
    )
    harness.monitor.onPressStart?()
    #expect(harness.recorder.isRecording, "the trigger does not dictate once the choice is over")
}

@MainActor
@Test("A key or mode changed while choosing is armed once, when the choice ends (F683)")
func aTriggerChangedWhileChoosingIsArmedWhenItEnds() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    // The Trigger mode picker, beside Change.
    harness.controller.hotkey = DictationHotkey(keyCode: f5, mode: .toggle)
    #expect(harness.monitor.startCount == 0, "the mode picker re-armed a paused trigger")
    #expect(!chooser.receive(.keyDown(keyCode: f6, isShortcut: false)))
    #expect(harness.monitor.startedHotkeys == [DictationHotkey(keyCode: f6, mode: .toggle)])
}

@MainActor
@Test("Choosing during a dictation leaves its trigger alone until it stops listening, then pauses it (F683)")
func aListeningDictationKeepsItsTrigger() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())
    harness.recorder.stopDuration = 0.1 // a tap, discarded, so the dictation ends without a model
    harness.monitor.onPressStart?()
    try #require(harness.controller.status == .listening)

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(harness.monitor.stopCount == 0, "the trigger of a dictation still listening was paused")
    #expect(harness.monitor.startCount == 0, "the trigger was re-armed under a live dictation (F446)")
    // Its own trigger ends it.
    harness.monitor.onPressEnd?()
    #expect(harness.recorder.stopCount == 1)
    #expect(harness.monitor.stopCount == 1, "the trigger was not paused once the dictation stopped listening")

    chooser.end()
    #expect(harness.monitor.startedHotkeys == [DictationHotkey(keyCode: f5, mode: .hold)])
}

@MainActor
@Test("A paused trigger is armed again when WhisperMeet goes to the background, even if no chooser says so (F683)")
func aPausedTriggerResumesInTheBackground() throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationTriggerChooserTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(try JSONEncoder().encode(DictationHotkey(keyCode: f5, mode: .hold)), forKey: "dictationHotkey")
    let monitor = FakeHotkeyMonitor()
    let notifications = NotificationCenter()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: isolatedTextInjector(),
        activationNotifications: notifications,
        activateOnInit: false
    )
    // A chooser that went away without ending its choice.
    controller.beginChoosingTrigger(by: NSObject())
    try #require(controller.isTriggerPausedForChoosing)

    notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(!controller.isChoosingTrigger)
    #expect(!controller.isTriggerPausedForChoosing, "the trigger stayed paused with no choice left to make")
    #expect(monitor.startedHotkeys == [DictationHotkey(keyCode: f5, mode: .hold)])
}

/// A toggle dictation ended by its F-key while Settings is choosing pauses the trigger under that
/// key-down, so the rest of the hold repeats into the Settings window.
@MainActor
@Test("A held key's autorepeat chooses nothing; a shortcut's still reaches the app (F683)")
func anAutorepeatChoosesNothing() throws {
    let harness = try Harness(hotkey: DictationHotkey(keyCode: f5, mode: .toggle))
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(!chooser.receive(.keyDown(keyCode: f6, isShortcut: false), isRepeat: true), "a repeat reached the window")
    #expect(chooser.isChoosing, "an autorepeat chose a trigger")
    #expect(chooser.hint == nil, "an autorepeat was refused as a key")
    #expect(chooser.receive(.keyDown(keyCode: 6, isShortcut: true), isRepeat: true), "a held ⌘Z stopped repeating")
    #expect(harness.controller.hotkey == DictationHotkey(keyCode: f5, mode: .toggle))
}

@MainActor
@Test("With Quick Dictation off, choosing a trigger arms nothing (F683)")
func choosingWithDictationOffArmsNothing() throws {
    let harness = try Harness(enabled: false)
    defer { harness.cleanUp() }
    let chooser = DictationTriggerChooser(monitors: MonitorLedger().monitors, notifications: NotificationCenter())

    chooser.toggle(in: NSObject(), for: harness.controller)
    #expect(!chooser.receive(.keyDown(keyCode: f6, isShortcut: false)))
    #expect(harness.controller.hotkey.keyCode == f6)
    #expect(harness.monitor.startCount == 0)
    #expect(harness.monitor.stopCount == 0)
}
