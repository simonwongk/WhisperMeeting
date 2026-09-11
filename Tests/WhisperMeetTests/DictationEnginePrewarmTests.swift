import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F202 — the transcription engine must prewarm on the press-down edge, so a post-eviction reload
/// (measured 11.4 s cold-to-ready) overlaps the user's speaking time instead of landing entirely
/// after key release.

@MainActor
private func makeController(
    engine: WarmUpCountingEngine,
    defaults: UserDefaults,
    directory: URL
) -> (DictationController, FakeHotkeyMonitor) {
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    return (controller, monitor)
}

/// Holds recognition warm-up open so the refinement toggle test can prove the optional 4B/8B model
/// never begins loading beside it.
private final class GatedWarmUpEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _warmUpCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var warmUpCount: Int { lock.withLock { _warmUpCount } }

    func warmUp() async throws {
        lock.withLock { _warmUpCount += 1 }
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }

    func shutdown() { releaseWarmUp() }

    func releaseWarmUp() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Keeps the meeting-admission edge explicit in queued-task tests. The controller runs on the
/// main actor, but its engine/refiner tasks yield before their subprocess calls, so this state is
/// lock-backed like the real AppModel closure boundary.
private final class MeetingActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool { lock.withLock { running } }
    func setRunning(_ value: Bool) { lock.withLock { running = value } }
}

@MainActor
@Test("Press-down that starts capture prewarms the transcription engine")
func pressDownPrewarmsEngine() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, monitor) = makeController(engine: engine, defaults: defaults, directory: directory)
    monitor.onPressStart?()
    for _ in 0..<100 where engine.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.status == .listening)
    #expect(engine.warmUpCount >= 1)
}

@MainActor
@Test("A refused press (microphone busy) does not prewarm the engine")
func refusedPressDoesNotPrewarm() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.busy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-busy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, monitor) = makeController(engine: engine, defaults: defaults, directory: directory)
    controller.configure(isMicrophoneBusy: { true })
    monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(60))
    #expect(controller.status != .listening)
    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("A failed microphone start does not prewarm the dictation model (F206)")
func failedCaptureStartDoesNotPrewarm() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.startFailure.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-startFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
    recorder.startError = NSError(domain: "DictationTest", code: 1)
    let engine = WarmUpCountingEngine()
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        activateOnInit: false
    )
    controller.clipboardNotifier = {}

    monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(80))

    #expect(controller.status != .listening)
    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("A meeting transcription blocks a new dictation before it warms another local model (F206)")
func meetingTranscriptionPreventsDictationPrewarm() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.meeting.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-meeting-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, monitor) = makeController(engine: engine, defaults: defaults, directory: directory)
    controller.configureMeetingTranscriptionRunning { true }
    monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(60))
    #expect(controller.status != .listening)
    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("Enabling dictation during a meeting defers background recognition warm-up (F206)")
func enablingDuringMeetingDefersRecognitionWarmUp() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.enable.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-enable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, _) = makeController(engine: engine, defaults: defaults, directory: directory)
    controller.configureMeetingTranscriptionRunning { true }
    controller.setEnabled(true)
    try await Task.sleep(for: .milliseconds(60))

    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("A queued recognition warm-up rechecks meeting admission before it launches (F206)")
func queuedRecognitionWarmUpRechecksMeetingAdmission() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.queuedRecognition.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-queuedRecognition-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, _) = makeController(engine: engine, defaults: defaults, directory: directory)
    let meeting = MeetingActivity()
    controller.configureMeetingTranscriptionRunning { meeting.isRunning }
    controller.setEnabled(true)
    // The task was admitted while idle, then a meeting claimed the resource before that task got
    // a chance to call the model. It must make no late subprocess launch.
    meeting.setRunning(true)
    try await Task.sleep(for: .milliseconds(60))

    #expect(engine.warmUpCount == 0)
}

@MainActor
@Test("A queued refiner warm-up rechecks meeting admission before it launches (F206)")
func queuedRefinerWarmUpRechecksMeetingAdmission() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.queuedRefiner.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationRefineEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-queuedRefiner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let refiner = FakeRefiner()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: refiner,
        activateOnInit: false
    )
    let meeting = MeetingActivity()
    controller.refineRuntimeAvailability = { true }
    controller.configureMeetingTranscriptionRunning { meeting.isRunning }
    controller.setEnabled(true)
    for _ in 0..<100 where engine.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    // Let the recognition task clear its own task marker before enabling the optional model.
    try await Task.sleep(for: .milliseconds(20))

    controller.refineEnabled = true
    meeting.setRunning(true)
    try await Task.sleep(for: .milliseconds(60))

    #expect(refiner.warmUpCount == 0)
}

@MainActor
@Test("Turning on refinement waits for an in-flight recognition warm-up (F206)")
func refinementToggleWaitsForRecognitionWarmUp() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.refine.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationRefineEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-refine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = GatedWarmUpEngine()
    let refiner = FakeRefiner()
    let controller = DictationController(
        defaults: defaults,
        engine: engine,
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        refiner: refiner,
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { true }
    controller.setEnabled(true)
    for _ in 0..<100 where engine.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }

    controller.refineEnabled = true
    try await Task.sleep(for: .milliseconds(30))
    #expect(refiner.warmUpCount == 0)

    engine.releaseWarmUp()
    for _ in 0..<100 where refiner.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(refiner.warmUpCount == 1)
}

@MainActor
@Test("A meeting transcription blocks the dictation self-test before it starts ASR (F206)")
func meetingTranscriptionPreventsDictationSelfTest() async throws {
    let suite = "WhisperMeet.DictationEnginePrewarmTests.selfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationEnginePrewarmTests-selfTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = WarmUpCountingEngine()
    let (controller, _) = makeController(engine: engine, defaults: defaults, directory: directory)
    controller.configureMeetingTranscriptionRunning { true }
    controller.runSelfTest()

    #expect(controller.isSelfTesting == false)
    #expect(engine.transcribeCount == 0)
    #expect(controller.selfTestResult?.contains("meeting transcription") == true)
}
