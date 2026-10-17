import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F847 — the "Chinese script" setting through the real controller: a Traditional reply from the
// recognizer is pasted in the chosen script, and the history keeps what was heard.

@MainActor
private func dictate(engineText: String, storedScript: String?) async throws -> (entry: DictationLogEntry, script: DictationChineseScript) {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F847-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    defaults.set(false, forKey: "dictationRefineEnabled")
    if let storedScript { defaults.set(storedScript, forKey: "dictationChineseScript") }
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: engineText),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: FakeRefiner(),
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.gpuUtilization = { nil }
    controller.clipboardNotifier = {}

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    monitor.onPressEnd?()
    let deadline = ContinuousClock.now + .seconds(30)
    while controller.logStore.log.entries.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let entry = try #require(controller.logStore.log.entries.first, "the dictation never finished")
    return (entry, controller.chineseScript)
}

@MainActor
@Test("A Traditional reply is pasted in Simplified when that is the chosen script, and the history keeps what was heard (F847)")
func aTraditionalReplyIsPastedInTheChosenScript() async throws {
    let (entry, script) = try await dictate(engineText: "幫我把今天的會議記要發給團隊", storedScript: "simplified")
    #expect(script == .simplified)
    #expect(entry.text == "帮我把今天的会议记要发给团队")
    #expect(entry.rawText == "幫我把今天的會議記要發給團隊")
}

@MainActor
@Test("With no choice stored, a test process reads As heard, never this Mac's languages (F847)")
func aTestProcessDefaultsToAsHeard() async throws {
    // The app's default follows the Mac's preferred language; a test must not depend on the host's.
    let (entry, script) = try await dictate(engineText: "幫我把今天的會議記要發給團隊", storedScript: nil)
    #expect(script == .asHeard)
    #expect(entry.text == "幫我把今天的會議記要發給團隊")
    #expect(entry.rawText == nil)
}

@Test("Settings offers the Chinese script choice beside the dictation language (F847)")
func settingsOffersTheChineseScriptChoice() throws {
    // ContentView cannot be rendered here (F174): its source is checked, comments stripped (F285).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("Picker(\"Chinese script\", selection: $dictation.chineseScript)"))
    #expect(source.contains("DictationChineseScript.allCases"))
}
