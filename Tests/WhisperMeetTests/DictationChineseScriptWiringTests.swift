import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F847 — the "Chinese script" setting through the real controller: a Traditional reply from the
// recognizer is pasted in the chosen script, and the history keeps what was heard. Round 3 (the
// round-2 review's C2 and C3): vocabulary terms keep their characters, a refiner or a rule cannot
// bring the other script back, and Japanese is not converted.

@MainActor
private func dictate(
    engineText: String,
    languageCode: String = "en",
    storedScript: String?,
    vocabulary: [String] = [],
    refined: RefineAttempt? = nil
) async throws -> (entry: DictationLogEntry, script: DictationChineseScript) {
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
    defaults.set(refined != nil, forKey: "dictationRefineEnabled")
    if let storedScript { defaults.set(storedScript, forKey: "dictationChineseScript") }
    let monitor = FakeHotkeyMonitor()
    let refiner = FakeRefiner()
    refiner.script(refined)
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: engineText, languageCode: languageCode),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: refiner,
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { true }
    controller.gpuUtilization = { nil }
    controller.clipboardNotifier = {}
    controller.configureVocabulary { vocabulary }
    controller.configureReplacementRules({ [] }, knownTerms: { vocabulary })

    if refined != nil {
        controller.setEnabled(true)
        let deadline = ContinuousClock.now + .seconds(30)
        while !controller.isRefinerReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(controller.isRefinerReady, "the refiner never warmed")
    }

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
    // The app's default follows the Mac's preferred languages; a test must not depend on the host's.
    let (entry, script) = try await dictate(engineText: "幫我把今天的會議記要發給團隊", storedScript: nil)
    #expect(script == .asHeard)
    #expect(entry.text == "幫我把今天的會議記要發給團隊")
    #expect(entry.rawText == nil)
}

@MainActor
@Test("A vocabulary name keeps its characters in a converted dictation (F847, the round-2 review's C2)")
func aVocabularyNameKeepsItsCharacters() async throws {
    // ICU's Traditional writes the surname 范 as 範; the user taught the app 范总.
    let (entry, _) = try await dictate(engineText: "范总明天来", storedScript: "traditional", vocabulary: ["范总"])
    #expect(entry.text == "范总明天來")
}

@MainActor
@Test("A refiner that answers in the other script cannot bring it back into the paste (F847, the round-2 review's C2)")
func theRefinerCannotBringTheOtherScriptBack() async throws {
    let (entry, _) = try await dictate(
        engineText: "帮我把会议纪要发给团队",
        storedScript: "simplified",
        refined: RefineAttempt(text: "幫我把會議紀要發給團隊。", outcome: .refined)
    )
    #expect(entry.text == "帮我把会议纪要发给团队。")
}

@MainActor
@Test("A reply Whisper detected as Japanese is pasted as heard (F847, the round-2 review's C3)")
func aJapaneseReplyIsNotConverted() async throws {
    let (entry, _) = try await dictate(engineText: "東京で会議があります", languageCode: "ja", storedScript: "simplified")
    #expect(entry.text == "東京で会議があります")
    #expect(entry.rawText == nil)
}

@Test("A script conversion is logged as one, not as a pinyin-name correction (F847, F768, the round-2 review's C10)")
func theLogTellsAConversionFromACorrection() {
    #expect(DictationController.textChangeNotes(recognized: "幫我", converted: "帮我", corrected: "帮我")
            == ["the dictation was written in the chosen Chinese script"])
    #expect(DictationController.textChangeNotes(recognized: "Wang老师", converted: "Wang老师", corrected: "王老师")
            == ["a vocabulary name written partly in pinyin was put back into characters"])
    #expect(DictationController.textChangeNotes(recognized: "Wang老師", converted: "Wang老师", corrected: "王老师").count == 2)
    #expect(DictationController.textChangeNotes(recognized: "hi", converted: "hi", corrected: "hi").isEmpty)
}

@Test("Settings offers the Chinese script choice beside the dictation language (F847)")
func settingsOffersTheChineseScriptChoice() throws {
    // ContentView cannot be rendered here (F174): its source is checked, comments stripped (F285).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("Picker(\"Chinese script\", selection: $dictation.chineseScript)"))
    #expect(source.contains("DictationChineseScript.allCases"))
}

@Test("The vocabulary switch works with every engine, and the Qwen caption says what it still does (F1029, the user's decision of 2026-10-17)")
func theVocabularySwitchWorksForEveryEngine() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let toggle = try #require(source.range(of: "Toggle(\"Use business vocabulary for dictation\", isOn: $dictation.useVocabulary)"))
    let after = source[toggle.upperBound...].prefix(240)
    #expect(!after.contains(".disabled("), "the switch is still greyed out for an engine: \(after)")
    #expect(!source.contains("Qwen does not currently accept Business Vocabulary prompts."))
    #expect(source.contains("Qwen doesn’t take a vocabulary hint, but your vocabulary still corrects names it writes half in pinyin."))
}
