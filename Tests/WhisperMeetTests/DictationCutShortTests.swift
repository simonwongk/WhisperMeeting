import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F1016 — the user's decision of 2026-10-16 ("Paste it and say so on the pill"): a dictation the
// recognizer cut short (F762's and F1015's `truncated`) is pasted as before, the pill says the end
// may be missing, and the dictation history marks it. Driven through the real controller with a
// scripted engine whose reply says it was cut, a private pasteboard, and an overlay that records
// what the pill showed.

private final class RecordingOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private func dictate(cutShort: Bool) async throws -> (entry: DictationLogEntry, phases: [DictationOverlay.Phase]) {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F1016-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    defaults.set(false, forKey: "dictationRefineEnabled")
    let monitor = FakeHotkeyMonitor()
    let overlay = RecordingOverlay()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: "我们的这个 Rem Let 这个", truncated: cutShort),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: overlay,
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
    return (entry, overlay.phases)
}

@MainActor
@Test("A dictation cut short is still delivered, the pill says the end may be missing, and the history marks it (F1016)")
func aCutShortDictationIsDeliveredAndMarked() async throws {
    let (entry, phases) = try await dictate(cutShort: true)
    // Delivered as before: auto-paste is off in this test, so it goes to the clipboard.
    #expect(entry.text == "我们的这个 Rem Let 这个")
    #expect(entry.outcome == .clipboard)
    #expect(entry.truncated == true, "the history does not mark the dictation as cut short")
    #expect(phases.contains(.endMayBeMissing(.copied)), "the pill showed \(phases)")
    #expect(DictationOverlay.Phase.endMayBeMissing(.copied).caption == "The end may be missing")
    #expect(DictationController.announcement(for: .endMayBeMissing(.copied))
            == "Dictation copied to the clipboard. The end may be missing.")
}

@MainActor
@Test("A dictation that was not cut short shows and records nothing new (F1016)")
func anOrdinaryDictationIsNotMarked() async throws {
    let (entry, phases) = try await dictate(cutShort: false)
    #expect(entry.truncated == nil)
    #expect(phases.contains(.copied))
    #expect(!phases.contains { if case .endMayBeMissing = $0 { true } else { false } })
}

@Test("The history row marks a cut-short dictation (F1016)")
func theHistoryRowMarksACutShortDictation() throws {
    // `DictationHistoryRow` cannot be rendered here (F174), so the view's source is checked for the
    // mark and the field that gates it, with comments stripped (F285).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(source.contains("entry.truncated == true"))
    #expect(source.contains("\"The end may be missing\""))
}
