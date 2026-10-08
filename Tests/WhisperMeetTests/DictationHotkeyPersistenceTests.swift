import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F548 — the trigger is stored as JSON in UserDefaults and read back at launch. A mode this build
/// does not know, from a newer build, used to fail the whole decode, and the fallback was Right
/// Option hold-to-talk: a live trigger on a key the user never chose, which the next change to any
/// dictation setting then wrote over their stored choice. This drives the launch path itself —
/// the stored bytes, `DictationController.init`, and the hotkey it arms.
@MainActor
@Test("A newer build's hotkey mode keeps the user's key, and saving other settings leaves it stored (F548)")
func newerBuildsHotkeyModeKeepsTheUsersKey() async throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationHotkeyPersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    // F5, in a mode only a newer build has.
    let newerBuildsBytes = Data(#"{"keyCode":96,"mode":"doubleTap"}"#.utf8)
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(newerBuildsBytes, forKey: "dictationHotkey")

    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: temporaryDirectory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activateOnInit: true // what the app does at launch
    )

    let f5Hold = DictationHotkey(keyCode: 96, mode: .hold)
    #expect(controller.hotkey == f5Hold)
    #expect(monitor.startedHotkeys == [f5Hold], "armed \(monitor.startedHotkeys), not the user's key")

    // Changing any other dictation setting re-saves the others. The stored trigger must survive
    // that, or going back to the newer build finds "hold" where the user's choice was.
    controller.autoPaste = false
    controller.language = .english
    #expect(defaults.data(forKey: "dictationHotkey") == newerBuildsBytes)

    // A trigger the user does choose is still saved.
    controller.hotkey = DictationHotkey(keyCode: 97, mode: .toggle)
    let saved = try #require(defaults.data(forKey: "dictationHotkey"))
    #expect(try JSONDecoder().decode(DictationHotkey.self, from: saved) == DictationHotkey(keyCode: 97, mode: .toggle))
}
