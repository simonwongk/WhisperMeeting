import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F206 — an idle Quick Dictation helper must be fully released before a meeting
/// engine starts, otherwise the two local models compete for unified memory.

private final class ResourceReleaseEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [String] {
        lock.withLock { values }
    }
}

private final class EvictTrackingDictationEngine: DictationEngine, @unchecked Sendable {
    private let events: ResourceReleaseEvents

    init(events: ResourceReleaseEvents) {
        self.events = events
    }

    func warmUp() async throws {}

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }

    func shutdown() {
        events.append("engine-shutdown")
    }

    func evict() async {
        events.append("engine-evicted")
    }
}

private final class EvictTrackingRefiner: DictationTextRefining, @unchecked Sendable {
    private let events: ResourceReleaseEvents

    init(events: ResourceReleaseEvents) {
        self.events = events
    }

    func warmUp() async -> Bool { true }

    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        RefineAttempt(text: text, outcome: .skipped)
    }

    func shutdown() {
        events.append("refiner-shutdown")
    }

    func evict() async {
        events.append("refiner-evicted")
    }
}

/// Holds both independent model exits at their first suspension point. This makes the release
/// ordering observable without a real model: a serial implementation never reaches the refiner
/// until the engine gate opens, while the production path should begin both exits immediately.
private final class ConcurrentEvictionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    private var released: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func wait(_ name: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            started.insert(name)
            if released.contains(name) {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations[name] = continuation
            lock.unlock()
        }
    }

    func release(_ name: String) {
        lock.lock()
        released.insert(name)
        let continuation = continuations.removeValue(forKey: name)
        lock.unlock()
        continuation?.resume()
    }

    var bothStarted: Bool {
        lock.withLock { started == ["engine", "refiner"] }
    }
}

private final class GatedEvictionEngine: DictationEngine, @unchecked Sendable {
    private let gate: ConcurrentEvictionGate

    init(gate: ConcurrentEvictionGate) {
        self.gate = gate
    }

    func warmUp() async throws {}

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }

    func shutdown() {}

    func evict() async {
        await gate.wait("engine")
    }
}

private final class GatedEvictionRefiner: DictationTextRefining, @unchecked Sendable {
    private let gate: ConcurrentEvictionGate

    init(gate: ConcurrentEvictionGate) {
        self.gate = gate
    }

    func warmUp() async -> Bool { true }

    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        RefineAttempt(text: text, outcome: .skipped)
    }

    func shutdown() {}

    func evict() async {
        await gate.wait("refiner")
    }
}

/// The warm task is deliberately allowed to yield so the test can make meeting preparation win
/// first, then prove the queued stale task cannot start a helper afterward.
private final class LateWarmEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _warmUpCount = 0

    var warmUpCount: Int { lock.withLock { _warmUpCount } }

    func warmUp() async throws {
        lock.withLock { _warmUpCount += 1 }
    }

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }

    func shutdown() {}

    func evict() async {
        // `releaseIdleModels…` has invalidated its generation before this suspension. A stale
        // MainActor warm-up task gets its chance to run here and must observe that invalidation.
        await Task.yield()
    }
}

@MainActor
@Test("Meeting transcription releases idle dictation models before invoking its engine (F206)")
func meetingTranscriptionReleasesIdleDictationModelsFirst() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "DictationMeetingResourceReleaseTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    let events = ResourceReleaseEvents()
    model.releaseIdleDictationModels = {
        events.append("released")
    }
    model.runTranscriptionEngineOverride = { _, _ in
        events.append("engine")
        return TranscriptionResult(
            id: "test", text: "local transcript", languageCode: "en",
            audioDuration: 1, confidence: nil, segments: []
        )
    }

    _ = try await model.executeEngine(
        MeetingTranscriptionSelection(engine: .qwenBalanced, language: .automatic),
        on: root.appendingPathComponent("synthetic.wav")
    )

    #expect(events.snapshot == ["released", "engine"])
}

@MainActor
@Test("Meeting preparation waits for both idle dictation helpers to evict (F206)")
func meetingPreparationEvictsBothIdleHelpers() async throws {
    let suite = "DictationMeetingResourceReleaseTests.Controller.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-controller-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let events = ResourceReleaseEvents()
    let controller = DictationController(
        defaults: defaults,
        engine: EvictTrackingDictationEngine(events: events),
        recorder: FakeDictationRecorder(outputURL: root.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: root),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: EvictTrackingRefiner(events: events),
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )

    await controller.releaseIdleModelsForMeetingTranscription()
    #expect(events.snapshot.count == 2)
    #expect(events.snapshot.contains("engine-evicted"))
    #expect(events.snapshot.contains("refiner-evicted"))
}

@MainActor
@Test("Meeting preparation starts both independent dictation evictions before awaiting either (F206)")
func meetingPreparationEvictsIdleHelpersConcurrently() async throws {
    let suite = "DictationMeetingResourceReleaseTests.concurrent.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-concurrent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let gate = ConcurrentEvictionGate()
    let controller = DictationController(
        defaults: defaults,
        engine: GatedEvictionEngine(gate: gate),
        recorder: FakeDictationRecorder(outputURL: root.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: root),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: GatedEvictionRefiner(gate: gate),
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )

    let release = Task { await controller.releaseIdleModelsForMeetingTranscription() }
    // Generous budget: a miss here is a false failure on a loaded machine, not a real serial path.
    for _ in 0..<400 where !gate.bothStarted {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(gate.bothStarted)
    gate.release("engine")
    gate.release("refiner")
    await release.value
}

@MainActor
@Test("Meeting preparation prevents an already queued idle warm-up from starting later (F206)")
func meetingPreparationCancelsQueuedWarmUp() async throws {
    let suite = "DictationMeetingResourceReleaseTests.queued.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-queued-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = LateWarmEngine()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: FakeDictationRecorder(outputURL: root.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: root),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: EvictTrackingRefiner(events: ResourceReleaseEvents()),
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )

    // `setEnabled` queues launch warming, but preparation reaches its generation invalidation
    // before the task can run. The yield in `evict()` lets that stale task observe the invalidation.
    controller.setEnabled(true)
    await controller.releaseIdleModelsForMeetingTranscription()
    for _ in 0..<10 { await Task.yield() }
    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("Every meeting engine path refuses while dictation is active (F206)")
func executeEngineRefusesActiveDictation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "DictationMeetingResourceReleaseTests.guard.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    let events = ResourceReleaseEvents()
    model.configureDictationGuard { true }
    model.releaseIdleDictationModels = { events.append("released") }
    model.runTranscriptionEngineOverride = { _, _ in
        events.append("engine")
        return TranscriptionResult(
            id: "test", text: "should not run", languageCode: "en",
            audioDuration: 1, confidence: nil, segments: []
        )
    }

    do {
        _ = try await model.executeEngine(
            MeetingTranscriptionSelection(engine: .qwenBalanced, language: .automatic),
            on: root.appendingPathComponent("synthetic.wav")
        )
        Issue.record("The engine should have refused while dictation is active.")
    } catch {
        #expect(error.localizedDescription.contains("Quick Dictation"))
    }
    #expect(events.snapshot.isEmpty)
}

@MainActor
@Test("Finishing an auxiliary meeting pass rewarms only dictation recognition (F206)")
func auxiliaryMeetingCompletionRewarmsDictationRecognition() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationMeetingResourceReleaseTests-rewarm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "DictationMeetingResourceReleaseTests.rewarm.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    let id = UUID()
    let segment = TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Synthetic",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: "hello",
        segments: [segment],
        transcriptionEngine: .whisperLarge
    ))
    let events = ResourceReleaseEvents()
    model.releaseIdleDictationModels = { events.append("released") }
    model.configureIdleDictationRecognitionWarmUp { events.append("rewarmed") }
    model.runTranscriptionEngineOverride = { _, _ in
        events.append("engine")
        return TranscriptionResult(
            id: "test", text: "hello", languageCode: "en",
            audioDuration: 1, confidence: nil, segments: [segment]
        )
    }

    model.requestSecondOpinion(id: id)
    while model.isRunningAuxiliaryEngine { await Task.yield() }
    #expect(events.snapshot == ["released", "engine", "rewarmed"])
}
