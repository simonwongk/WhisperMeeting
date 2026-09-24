import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F206 — a cold optional refiner must not turn the first Quick Dictation after an
/// eviction or launch into a multi-second wait. This drives the real controller
/// through a press/release with a refiner whose warm-up is deliberately blocked.

private final class ColdRefinementRecorder: DictationRecording {
    var onCaptureInterrupted: (@Sendable (DictationCaptureInterruption) -> Void)?
    private(set) var isRecording = false
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func requestPermission() async -> Bool { true }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        isRecording = true
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        isRecording = false
        return (outputURL, 1)
    }

    func cancel() {
        isRecording = false
    }
}

@MainActor
private final class ColdRefinementOverlay: DictationOverlayPresenting {
    func show(_ phase: DictationOverlay.Phase) {}
    func update(level: Float) {}
    func hide() {}
}

private struct ColdRefinementEngine: DictationEngine {
    func warmUp() async throws {}

    func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "raw first dictation", languageCode: "en")
    }

    func shutdown() {}
}

private final class ColdRefinementHotkey: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onPressCancel: (() -> Void)?

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool { true }

    func stop() {}
    func resetToggleState() {}
}

/// Simulates a refiner whose model load remains blocked until test cleanup.
/// `releaseWarmUp()` keeps cleanup deterministic after the assertion has observed
/// the controller's behavior.
private final class BlockingColdRefiner: DictationTextRefining, @unchecked Sendable {
    private let lock = NSLock()
    private var _warmUpCount = 0
    private var _attemptCount = 0
    private var _evictCount = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var warmUpCount: Int { lock.withLock { _warmUpCount } }
    var attemptCount: Int { lock.withLock { _attemptCount } }
    var evictCount: Int { lock.withLock { _evictCount } }

    func warmUp() async -> Bool {
        lock.withLock { _warmUpCount += 1 }
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
        return true
    }

    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        lock.withLock { _attemptCount += 1 }
        // If the controller calls this while warm-up is blocked, the test will
        // also expose the wrong user-visible delivery rather than merely a count.
        return RefineAttempt(text: "polished text must not delay the first delivery", outcome: .refined)
    }

    func shutdown() {
        releaseWarmUp()
    }

    func evict() async {
        lock.withLock { _evictCount += 1 }
        releaseWarmUp()
    }

    func releaseWarmUp() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
@Test("A cold optional refiner delivers raw text first and keeps warming for the next dictation")
func coldRefinerNeverBlocksFirstDictation() async throws {
    let suite = "WhisperMeet.DictationColdRefinementTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationColdRefinementTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let refiner = BlockingColdRefiner()
    defer {
        refiner.releaseWarmUp()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationRefineEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let monitor = ColdRefinementHotkey()
    let controller = DictationController(
        defaults: defaults,
        engine: ColdRefinementEngine(),
        recorder: ColdRefinementRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: ColdRefinementOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: refiner,
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { true }
    controller.clipboardNotifier = {}

    monitor.onPressStart?()
    // Recognition gets the first claim on memory after an idle eviction. Starting the
    // 8B refiner alongside it caused a short Qwen dictation to take more than 10 s.
    try await Task.sleep(for: .milliseconds(25))
    #expect(refiner.warmUpCount == 0)

    monitor.onPressEnd?()
    for _ in 0..<300 where controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }

    let entry = controller.logStore.log.entries.first
    #expect(entry?.text == "raw first dictation")
    #expect(entry?.refinement == nil)
    #expect(refiner.attemptCount == 0)
    // The load starts only after the session has fully dismissed to idle, ready to benefit the
    // next dictation without contending with the raw delivery or a rapid next press.
    for _ in 0..<300 where controller.status != .idle {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 where refiner.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(refiner.warmUpCount == 1)
}

@MainActor
@Test("A rapid next dictation evicts a still-cold optional refiner before ASR starts")
func rapidNextDictationCancelsColdRefiner() async throws {
    let suite = "WhisperMeet.DictationColdRefinementTests.rapid.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationColdRefinementTests-rapid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let refiner = BlockingColdRefiner()
    defer {
        refiner.releaseWarmUp()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(true, forKey: "dictationRefineEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let monitor = ColdRefinementHotkey()
    let controller = DictationController(
        defaults: defaults,
        engine: ColdRefinementEngine(),
        recorder: ColdRefinementRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: ColdRefinementOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: refiner,
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { true }
    controller.clipboardNotifier = {}

    monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(20))
    monitor.onPressEnd?()
    for _ in 0..<300 where controller.status != .idle {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 where refiner.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(refiner.warmUpCount == 1)

    // The first idle warm is deliberately blocked. A new press must terminate it during capture
    // rather than let an 8B model cold-load beside this second ASR request.
    monitor.onPressStart?()
    for _ in 0..<100 where refiner.evictCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    monitor.onPressEnd?()
    for _ in 0..<300 where controller.logStore.log.entries.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(refiner.evictCount == 1)
    #expect(refiner.attemptCount == 0)
    #expect(controller.logStore.log.entries.count == 2)
    #expect(controller.logStore.log.entries.first?.text == "raw first dictation")
}
