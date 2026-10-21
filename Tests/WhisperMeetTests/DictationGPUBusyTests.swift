import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F890 — a busy GPU before recognition means the optional refiner is not consulted: its own pass
/// would miss the budget it is given and deliver raw text later than delivering it now. Driven
/// headlessly through the injected seams; the GPU reading is the `gpuUtilization` seam, so these
/// tests say nothing about this machine's GPU.

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let refiner: FakeRefiner
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init() throws {
        suite = testSuiteName()
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationGPUBusyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(true, forKey: "dictationRefineEnabled")
        monitor = FakeHotkeyMonitor()
        refiner = FakeRefiner()
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: "hello there"),
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: refiner,
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.refineRuntimeAvailability = { true }
        controller.clipboardNotifier = {}
        refiner.script(RefineAttempt(text: "Hello there.", outcome: .refined))
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The refiner must be resident before a dictation consults it (the F200 wiring tests' rule).
    func warmRefiner() async throws {
        controller.setEnabled(true)
        try await pollUntil("the refiner to warm") { refiner.warmUpCount >= 1 }
        for _ in 0..<5 { await Task.yield() }
    }

    func dictateOnce() async throws {
        monitor.onPressStart?()
        try await Task.sleep(for: .milliseconds(20))
        monitor.onPressEnd?()
        try await pollUntil("the dictation to be logged") { !controller.logStore.log.entries.isEmpty }
    }
}

@MainActor
@Test("A GPU busy at the threshold before recognition skips refinement and delivers raw text")
func busyGPUSkipsRefinement() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    harness.controller.gpuUtilization = { DictationController.refineSkipGPUBusyPercent }
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 0)
    let entry = harness.controller.logStore.log.entries.first
    #expect(entry?.text == "hello there")
    #expect(entry?.rawText == nil)
    #expect(entry?.refinement == DictationRefinement.rawGPUBusy.rawValue)
}

@MainActor
@Test("A GPU below the threshold leaves refinement exactly as it was")
func idleGPURefinesAsBefore() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    harness.controller.gpuUtilization = { DictationController.refineSkipGPUBusyPercent - 1 }
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 1)
    let entry = harness.controller.logStore.log.entries.first
    #expect(entry?.text == "Hello there.")
    #expect(entry?.refinement == "refined")
}

@MainActor
@Test("A GPU that cannot be read never skips refinement")
func unreadableGPURefines() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    harness.controller.gpuUtilization = { nil }
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 1)
    #expect(harness.controller.logStore.log.entries.first?.refinement == "refined")
}

@Test("The refine report counts a GPU-busy skip as not attempted, like a policy skip")
func reportTreatsGPUBusyAsNotAttempted() {
    let entries = [
        DictationLogEntry(
            id: UUID(), date: Date(), text: "hello there", outcome: .pasted,
            rawText: nil, refinement: DictationRefinement.rawGPUBusy.rawValue
        ),
    ]
    let report = DictationRefineReport(log: DictationLog(entries: entries))
    var tally = (total: 0, attempted: 0, unrecognised: 0)
    for bucket in DictationRefineReport.Bucket.allCases {
        guard let counted = report.bucket(bucket) else { continue }
        tally.total += counted.total
        tally.attempted += counted.attempted
        tally.unrecognised += counted.unrecognised
    }
    #expect(tally.total == 1)
    #expect(tally.attempted == 0)
    #expect(tally.unrecognised == 0)
}

/// F1052 — F245 meant the refiner to keep every term the user taught the app ("the whole vocabulary, not the
/// prompt-capped slice"), and it was handed the prompt-capped slice: at most 100 terms and 1,000 characters,
/// Han terms sorting last. F768 restores a name from the whole list, so a name it had just written was one the
/// refiner was free to rewrite. Driven with a prompt slice that leaves the name out.
@MainActor
@Test("The refiner keeps every vocabulary term, not only the 100 the recognizer is prompted with (F1052)")
func theRefinerKeepsTheWholeVocabulary() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let whole = (1...150).map { "Term\($0)" } + ["王老师"]
    harness.controller.configureVocabulary { Array(whole.prefix(100)) }
    harness.controller.configureReplacementRules({ [] }, knownTerms: { whole })
    harness.controller.gpuUtilization = { 0 }
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 1, "fixture: the refiner was not consulted")
    let kept = Set(harness.refiner.lastProtectedTerms ?? [])
    #expect(kept.contains("王老师"), "a name outside the prompt's 100 terms was left unprotected")
    #expect(kept.isSuperset(of: whole))
}
