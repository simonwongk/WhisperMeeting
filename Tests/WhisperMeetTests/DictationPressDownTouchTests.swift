import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F891 — a press-down wakes the resident models. Measured 2026-10-09 (`Scripts/bench/dictation-latency.py`
/// condition I): after 150 s idle on the user's Mac, the recognizer's first request took 0.70 s instead
/// of 0.32 and the resident refiner's 2.31 s instead of 0.72 (past its budget); their weights had been
/// compressed or paged out; the user's 6.9 s case reads as the same page-in, from disk. So on press-down,
/// after the recognizer's warm-up, the controller sends each resident model one tiny request, so the
/// page-in overlaps the user's speech — the overlap F202 already uses for a cold load. Driven through
/// the injected seams; the fakes record the order of calls.

/// Records warm-ups, touches and transcriptions in the order they arrive; `touch` can be told to throw.
private final class OrderRecordingEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var touchError: Error?
    var events: [String] { lock.withLock { _events } }
    func warmUp() async throws { lock.withLock { _events.append("warmUp") } }
    func touch() async throws {
        lock.withLock { _events.append("touch") }
        if let touchError { throw touchError }
    }
    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        lock.withLock { _events.append("transcribe") }
        return DictationResult(text: "hello there", languageCode: "en")
    }
    func shutdown() {}
}

private struct TouchFailure: Error {}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ value: Bool) { lock.withLock { flag = value } }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let engine: OrderRecordingEngine
    let refiner: FakeRefiner
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init(refineEnabled: Bool) throws {
        suite = testSuiteName()
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationPressDownTouchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(refineEnabled, forKey: "dictationRefineEnabled")
        monitor = FakeHotkeyMonitor()
        engine = OrderRecordingEngine()
        refiner = FakeRefiner()
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: refiner,
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.refineRuntimeAvailability = { refineEnabled }
        controller.gpuUtilization = { nil }
        controller.clipboardNotifier = {}
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Enable, and wait for the background warm-up (and the refiner's, when on) to settle.
    func enableAndSettle() async throws {
        controller.setEnabled(true)
        for _ in 0..<300 where !engine.events.contains("warmUp") {
            try await Task.sleep(for: .milliseconds(10))
        }
        if controller.refineEnabled {
            for _ in 0..<300 where refiner.warmUpCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        for _ in 0..<5 { await Task.yield() }
    }

    func pressAndWait(for event: String) async throws {
        monitor.onPressStart?()
        for _ in 0..<300 where !engine.events.contains(event) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseAndWaitForDelivery() async throws {
        monitor.onPressEnd?()
        for _ in 0..<300 where controller.logStore.log.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.logStore.log.entries.isEmpty)
    }
}

@MainActor
@Test("Press-down touches the recognizer after its warm-up and before the clip is transcribed")
func pressDownTouchesTheRecognizerAfterWarmUp() async throws {
    let harness = try Harness(refineEnabled: false)
    defer { harness.tearDown() }
    try await harness.enableAndSettle()
    #expect(!harness.engine.events.contains("touch"), "enabling must not touch: a fresh helper is hot")
    try await harness.pressAndWait(for: "touch")
    try await harness.releaseAndWaitForDelivery()
    let events = harness.engine.events
    #expect(events.filter { $0 == "touch" }.count == 1)
    let warmUp = try #require(events.lastIndex(of: "warmUp"))
    let touch = try #require(events.firstIndex(of: "touch"))
    let transcribe = try #require(events.firstIndex(of: "transcribe"))
    #expect(warmUp < touch && touch < transcribe)
}

@MainActor
@Test("A touch that fails does not fail the dictation")
func failedTouchStillDelivers() async throws {
    let harness = try Harness(refineEnabled: false)
    defer { harness.tearDown() }
    harness.engine.touchError = TouchFailure()
    try await harness.enableAndSettle()
    try await harness.pressAndWait(for: "touch")
    try await harness.releaseAndWaitForDelivery()
    #expect(harness.controller.logStore.log.entries.first?.text == "hello there")
    #expect(harness.engine.events.contains("transcribe"))
}

@MainActor
@Test("Press-down touches a resident refiner after the recognizer, and never a cold one")
func pressDownTouchesOnlyAWarmRefiner() async throws {
    let warm = try Harness(refineEnabled: true)
    defer { warm.tearDown() }
    try await warm.enableAndSettle()
    #expect(warm.refiner.touchCount == 0)
    let engine = warm.engine
    let engineTouchedFirst = LockedFlag()
    warm.refiner.onTouch = { engineTouchedFirst.set(engine.events.contains("touch")) }
    try await warm.pressAndWait(for: "touch")
    for _ in 0..<300 where warm.refiner.touchCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(warm.refiner.touchCount == 1)
    #expect(engineTouchedFirst.value == true)
    try await warm.releaseAndWaitForDelivery()

    let cold = try Harness(refineEnabled: false)
    defer { cold.tearDown() }
    try await cold.enableAndSettle()
    try await cold.pressAndWait(for: "touch")
    try await cold.releaseAndWaitForDelivery()
    #expect(cold.refiner.touchCount == 0)
}
