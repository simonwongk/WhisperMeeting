import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F768 — the user's decision of 2026-10-16 (relayed by whisper-dfd4, recorded on the ticket): a
// Business Vocabulary name the recognizer wrote half in pinyin ("Wang老师") is put back into
// characters before pasting. Driven through the real controller (fake recorder, scripted engine,
// private pasteboard), so the correction is asserted where it reaches the user: the delivered text,
// which the history records, with the recognizer's own text kept beside it.

@MainActor
private func dictate(engineText: String, vocabulary: [String], useVocabulary: Bool = true) async throws -> DictationLogEntry {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F768-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    defaults.set(false, forKey: "dictationRefineEnabled")
    defaults.set(useVocabulary, forKey: "dictationUseVocabulary")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: engineText),
        // No file at the clip's path: F599's speech floor reads that as "cannot tell".
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
    controller.configureVocabulary { vocabulary }

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    monitor.onPressEnd?()
    let deadline = ContinuousClock.now + .seconds(30)
    while controller.logStore.log.entries.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    return try #require(controller.logStore.log.entries.first, "the dictation never finished")
}

@MainActor
@Test("A vocabulary name written half in pinyin is pasted in characters, and the history keeps what was heard (F768)")
func aHalfPinyinVocabularyNameIsPastedInCharacters() async throws {
    let entry = try await dictate(engineText: "我今晚 ping 一下 Wang老师 作业的事。", vocabulary: ["王老师"])
    #expect(entry.text == "我今晚 ping 一下 王老师 作业的事。")
    #expect(entry.rawText == "我今晚 ping 一下 Wang老师 作业的事。")
}

@MainActor
@Test("Without the term in the vocabulary, or with vocabulary off for dictation, the name stays as heard (F768)")
func aNameOutsideTheVocabularyStaysAsHeard() async throws {
    let notInVocabulary = try await dictate(engineText: "跟Wang老师说", vocabulary: ["李老师"])
    #expect(notInVocabulary.text == "跟Wang老师说")
    #expect(notInVocabulary.rawText == nil)
    let vocabularyOff = try await dictate(engineText: "跟Wang老师说", vocabulary: ["王老师"], useVocabulary: false)
    #expect(vocabularyOff.text == "跟Wang老师说")
}
