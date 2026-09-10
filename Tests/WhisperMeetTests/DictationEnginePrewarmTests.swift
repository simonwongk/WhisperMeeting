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
