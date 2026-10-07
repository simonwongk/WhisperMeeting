import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F821 — Quick Dictation applies the user's replacement rules before pasting: the user's decision of
// 2026-10-07, asked by whisper-dfd4 with two options. Until then `ReplacementRule` had no caller
// outside a meeting's Improve sheet. Driven through the real controller (fake recorder, scripted
// engine and refiner, private pasteboard), so the rules are asserted where they reach the user: the
// text delivered, which is what the history records.

/// A fixed Chinese segmentation, so nothing depends on this Mac's NLTokenizer dictionary: 会议厅 is
/// one word, 会议纪要 is 会议 | 纪要 — what NLTokenizer was measured to do (F594).
private let pinnedSegmenter: CJKWordEvidence.Segmenter = { text in
    let words = ["整理", "会议厅", "会议", "纪要", "明天", "开", "我们", "在", "讨论"]
    var ranges: [Range<String.Index>] = []
    var index = text.startIndex
    outer: while index < text.endIndex {
        for word in words where text[index...].hasPrefix(word) {
            let end = text.index(index, offsetBy: word.count)
            ranges.append(index..<end)
            index = end
            continue outer
        }
        index = text.index(after: index)
    }
    return ranges
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let refiner = FakeRefiner()
    let cleanUp: () -> Void

    init(engineText: String, refineEnabled: Bool = false) throws {
        let suite = "WhisperMeet.DictationReplacementRuleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationReplacementRuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(refineEnabled, forKey: "dictationRefineEnabled")
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: engineText),
            // No file at the clip's path: F599's speech floor reads that as "cannot tell" and sends
            // the clip on to the engine.
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
        controller.clipboardNotifier = {} // UNUserNotificationCenter crashes without an app bundle
        controller.cjkWordSegmenter = pinnedSegmenter
    }

    /// The optional refiner warms only in an idle period after enabling (F206); wait for it, so the
    /// dictation below takes the refinement path.
    func warmRefiner() async throws {
        controller.setEnabled(true)
        let deadline = ContinuousClock.now + .seconds(30)
        while refiner.warmUpCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(refiner.warmUpCount >= 1, "the refiner never warmed")
        // `warmUp()` counts just before the controller records it as warm on the main actor.
        let settled = ContinuousClock.now + .seconds(30)
        while !controller.isRefinerReady, ContinuousClock.now < settled {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(controller.isRefinerReady, "the controller never recorded the refiner as warm")
    }

    /// One press and release; returns once the dictation's outcome is in the history.
    func dictate() async throws -> DictationLogEntry {
        monitor.onPressStart?()
        try #require(controller.status == .listening)
        monitor.onPressEnd?()
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.logStore.log.entries.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(controller.logStore.log.entries.first, "the dictation never finished")
    }
}

@MainActor
@Test("With refinement off, the user's rules are applied before pasting, with the Improve sheet's word edges (F821)")
func dictationAppliesReplacementRulesToRawText() async throws {
    let harness = try Harness(engineText: "Ask Jon and Jones to 整理会议纪要，我们在会议厅讨论，明天开会议")
    defer { harness.cleanUp() }
    harness.controller.configureReplacementRules(
        { [ReplacementRule(heard: "Jon", preferred: "Jonathan"), ReplacementRule(heard: "会议", preferred: "会议室")] },
        knownTerms: { ["会议纪要"] }
    )

    let entry = try await harness.dictate()

    // Jones is a longer Latin word; 会议纪要 is a vocabulary term; 会议厅 is one word to the segmenter.
    #expect(entry.text == "Ask Jonathan and Jones to 整理会议纪要，我们在会议厅讨论，明天开会议室")
    #expect(entry.outcome == .clipboard)
    // The history keeps what the recognizer heard beside what was pasted.
    #expect(entry.rawText == "Ask Jon and Jones to 整理会议纪要，我们在会议厅讨论，明天开会议")
    #expect(entry.refinement == nil)
}

@MainActor
@Test("Rules apply to the refined text when refinement is accepted (F821)")
func dictationAppliesReplacementRulesAfterRefinement() async throws {
    let harness = try Harness(engineText: "um ask jon about it", refineEnabled: true)
    defer { harness.cleanUp() }
    harness.refiner.script(RefineAttempt(text: "Ask Jon about it.", outcome: .refined))
    harness.controller.configureReplacementRules(
        { [ReplacementRule(heard: "Jon", preferred: "Jonathan")] }, knownTerms: { [] }
    )
    try await harness.warmRefiner()

    let entry = try await harness.dictate()

    #expect(harness.refiner.attemptCount == 1)
    #expect(entry.text == "Ask Jonathan about it.")
    #expect(entry.rawText == "um ask jon about it")
    #expect(entry.refinement == "refined")
}

@MainActor
@Test("Rules apply to the raw text when refinement is refused (F821)")
func dictationAppliesReplacementRulesWhenRefinementIsRefused() async throws {
    let harness = try Harness(engineText: "ask Jon about it", refineEnabled: true)
    defer { harness.cleanUp() }
    harness.refiner.script(RefineAttempt(text: "ask Jon about it", outcome: .rawRejected))
    harness.controller.configureReplacementRules(
        { [ReplacementRule(heard: "Jon", preferred: "Jonathan")] }, knownTerms: { [] }
    )
    try await harness.warmRefiner()

    let entry = try await harness.dictate()

    #expect(harness.refiner.attemptCount == 1)
    #expect(entry.text == "ask Jonathan about it")
    #expect(entry.rawText == "ask Jon about it")
    #expect(entry.refinement == "rawRejected")
}

@MainActor
@Test("A rule that matches nothing leaves the dictation and its history entry as before (F821 control)")
func dictationWithoutAMatchingRuleIsUnchanged() async throws {
    let harness = try Harness(engineText: "Jones said hello")
    defer { harness.cleanUp() }
    harness.controller.configureReplacementRules(
        { [ReplacementRule(heard: "Jon", preferred: "Jonathan")] }, knownTerms: { [] }
    )

    let entry = try await harness.dictate()

    #expect(entry.text == "Jones said hello")
    #expect(entry.rawText == nil)
}

@MainActor
@Test("The app hands dictation its replacement rules and stored vocabulary, and the default segmenter is NLTokenizer's (F821)")
func appWiresReplacementRulesIntoDictation() throws {
    let code = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(code.contains("dictation.configureReplacementRules("))
    #expect(code.contains("model?.store.replacementRules"))
    #expect(code.contains("knownTerms: { [weak model] in model?.store.vocabulary"))

    let suite = "WhisperMeet.F821.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("F821-\(UUID().uuidString)")),
        refiner: FakeRefiner(),
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    let text = "整理会议纪要 then Kubernetes集群，明天开会议。"
    #expect(controller.cjkWordSegmenter(text).map { String(text[$0]) }
        == NaturalLanguageWordSegmenter.wordRanges(in: text).map { String(text[$0]) })
}
