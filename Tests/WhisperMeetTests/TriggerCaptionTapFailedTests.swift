import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F926 — with neither Accessibility nor Input Monitoring granted, the trigger's tap is never created
// (`start` fails), so no key is held back from any app. Settings' caption still said so: an F-key "the
// app you are typing in does not receive", a modifier "An F-key is kept from that app instead". Both
// were promises about a tap that did not exist. Driven through the controller, with the monitor's start
// refused as it is on such a Mac (the review's probe P1).

@MainActor
private func controller(hotkey: DictationHotkey, in directory: URL) throws -> DictationController {
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(try JSONEncoder().encode(hotkey), forKey: "dictationHotkey")
    let monitor = FakeHotkeyMonitor()
    monitor.startResult = false
    let controller = DictationController(
        defaults: defaults, engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(), hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory), refiner: RefusedDictationRefiner(),
        textInjector: isolatedTextInjector(), applicationSupport: directory, activateOnInit: false
    )
    controller.accessibilityTrusted = { false }
    controller.setEnabled(true)
    return controller
}

@MainActor
@Test("With no tap at all, the trigger caption says the key is not heard and reaches every app (F926)")
func aTriggerThatCouldNotBeArmedSaysSo() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F926-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for hotkey in [DictationHotkey(keyCode: 96, mode: .hold), DictationHotkey.rightOption] {
        let caption = try controller(hotkey: hotkey, in: directory).triggerKeyCaption
        #expect(!caption.contains("does not receive it"), "\(caption)")
        #expect(!caption.contains("kept from that app"), "\(caption)")
        #expect(caption.contains("cannot hear this key"), "\(caption)")
        #expect(caption.contains("Accessibility"), "it should say what to allow: \(caption)")
    }
}

@Test("Without Accessibility, a modifier's caption no longer promises an F-key would be kept from the app (F926)")
func aModifierCaptionWithoutAccessibilityPromisesNothing() {
    let listening = DictationController.triggerKeyCaption(
        for: .rightOption, isListenOnly: true, accessibilityGranted: false
    )
    #expect(!listening.contains("An F-key is kept from that app instead"), "\(listening)")
    // With the grant, it is true, and still said.
    let granted = DictationController.triggerKeyCaption(for: .rightOption, isListenOnly: false, accessibilityGranted: true)
    #expect(granted.contains("An F-key is kept from that app instead"), "\(granted)")
}
