import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F206 — a timed-out polish is deliberately allowed to finish in the background so raw text can
/// arrive at its deadline. Before the *next* recognition warm-up, however, that still-running
/// helper must be gone. This test blocks eviction to make the ordering observable rather than
/// assuming a fast fake teardown represents a multi-GB local model.

private final class RefinerReleaseOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    func reset() {
        lock.withLock { values.removeAll() }
    }

    var events: [String] { lock.withLock { values } }
}

private final class OrderedRecognitionEngine: DictationEngine, @unchecked Sendable {
    private let order: RefinerReleaseOrder

    init(order: RefinerReleaseOrder) {
        self.order = order
    }

    func warmUp() async throws {
        order.append("recognition-warm")
    }

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "raw transcript", languageCode: "en")
    }

    func shutdown() {}
}

private final class TimedOutRefiner: DictationTextRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let order: RefinerReleaseOrder
    private var _evictCount = 0
    private var shouldReleaseEviction = false
    private var evictionContinuation: CheckedContinuation<Void, Never>?

    init(order: RefinerReleaseOrder) {
        self.order = order
    }

    var evictCount: Int { lock.withLock { _evictCount } }

    func warmUp() async -> Bool {
        order.append("refiner-warm")
        return true
    }

    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        order.append("refiner-timeout")
        return RefineAttempt(text: text, outcome: .rawTimeout)
    }

    func shutdown() {
        // Production shutdown requests child termination but cannot promise its exit has already
        // been observed. Keep that distinction explicit so `evict()` remains the ordering point.
        order.append("refiner-shutdown")
    }

    func evict() async {
        lock.withLock { _evictCount += 1 }
        order.append("refiner-evict-start")
        await withCheckedContinuation { continuation in
            lock.lock()
            if shouldReleaseEviction {
                lock.unlock()
                continuation.resume()
                return
            }
            evictionContinuation = continuation
            lock.unlock()
        }
        order.append("refiner-evict-end")
    }

    func releaseEviction() {
        lock.lock()
        shouldReleaseEviction = true
        let continuation = evictionContinuation
        evictionContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
@Test("A timed-out refiner is evicted before a rapid next dictation warms recognition (F206)")
func timedOutRefinerReleasesBeforeNextRecognitionWarmUp() async throws {
    let suite = "WhisperMeet.DictationRefinerReleaseOrderingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationRefinerReleaseOrderingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationRefineEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let order = RefinerReleaseOrder()
    let engine = OrderedRecognitionEngine(order: order)
    let refiner = TimedOutRefiner(order: order)
    defer { refiner.releaseEviction() }
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: refiner,
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { true }
    controller.clipboardNotifier = {}
    controller.setEnabled(true)

    for _ in 0..<100 where !order.events.contains("refiner-warm") {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(order.events.contains("refiner-warm"))

    monitor.onPressStart?()
    monitor.onPressEnd?()
    for _ in 0..<300 where controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.logStore.log.entries.first?.refinement == DictationRefinement.rawTimeout.rawValue)
    for _ in 0..<300 where controller.status != .idle {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == .idle)

    order.reset()
    monitor.onPressStart?()
    for _ in 0..<100 where refiner.evictCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(refiner.evictCount == 1)
    #expect(order.events.contains("refiner-evict-start"))
    #expect(!order.events.contains("recognition-warm"))

    refiner.releaseEviction()
    for _ in 0..<100 where !order.events.contains("recognition-warm") {
        try await Task.sleep(for: .milliseconds(10))
    }
    let events = order.events
    guard let releaseEnd = events.firstIndex(of: "refiner-evict-end"),
          let recognitionWarm = events.firstIndex(of: "recognition-warm") else {
        Issue.record("Expected refiner eviction completion and the next recognition warm-up, got \(events)")
        return
    }
    #expect(releaseEnd < recognitionWarm)
}
