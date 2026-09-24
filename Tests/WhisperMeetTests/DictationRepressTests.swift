import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F443 — once a dictation has delivered (or failed), the pill stays up for a moment before the
/// session is dismissed: 1.1 s after a paste, 1.3 s after an empty result, 1.6 s after a failure.
/// A press inside that window used to be refused as "busy" with nothing on screen, so the user who
/// dictates sentence after sentence — or retries straight after a failure — lost the second press.

@MainActor
private final class PhaseRecordingOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

private struct FailingDictationEngine: DictationEngine {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The helper stopped." }
    }
    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        throw Failure()
    }
    func shutdown() {}
}

/// Holds every transcription until the test opens the gate, so a dictation can be kept in flight.
private final class GatedDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if open { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return DictationResult(text: "held transcript", languageCode: "en")
    }
    func shutdown() {}

    func openGate() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiting.removeAll() }
            return waiting
        }
        pending.forEach { $0.resume() }
    }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let recorder: FakeDictationRecorder
    let monitor: FakeHotkeyMonitor
    let overlay: PhaseRecordingOverlay
    let cleanup: () -> Void

    init(engine: any DictationEngine) throws {
        let suite = "WhisperMeet.DictationRepressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationRepressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        monitor = FakeHotkeyMonitor()
        overlay = PhaseRecordingOverlay()
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: recorder,
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// One whole dictation, press to settled result, waiting on the log entry every outcome writes.
    /// The polled value is the precondition for everything after it, so it is required.
    func dictateOnce() async throws {
        let before = controller.logStore.log.entries.count
        monitor.onPressStart?()
        try #require(recorder.isRecording, "the first press did not start a capture")
        monitor.onPressEnd?()
        for _ in 0..<1_000 where controller.logStore.log.entries.count == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.logStore.log.entries.count == before + 1, "the first dictation never settled")
    }
}

@MainActor
@Test("A press right after a dictation is delivered starts the next one (F443)")
func pressRightAfterDeliveryStartsANewDictation() async throws {
    let harness = try Harness(engine: FixedTextDictationEngine(text: "first sentence"))
    defer { harness.cleanup() }
    try await harness.dictateOnce()
    // Still inside the post-delivery window: the dismiss has not run yet.
    try #require(harness.controller.status == .delivering, "the dismiss window had already closed")

    harness.monitor.onPressStart?()

    #expect(harness.recorder.isRecording)
    #expect(harness.controller.status == .listening)
    #expect(harness.overlay.phases.last == .listening)

    // The first dictation's dismiss was due 1.1 s after its delivery. It must not end this capture.
    try await Task.sleep(for: .milliseconds(1_500))
    #expect(harness.recorder.isRecording)
    #expect(harness.controller.status == .listening)
}

@MainActor
@Test("A press right after a failed dictation retries at once (F443)")
func pressRightAfterFailureStartsANewDictation() async throws {
    let harness = try Harness(engine: FailingDictationEngine())
    defer { harness.cleanup() }
    try await harness.dictateOnce()
    guard case .error = harness.controller.status else {
        Issue.record("expected the failure to be showing, got \(harness.controller.status)")
        return
    }

    harness.monitor.onPressStart?()

    #expect(harness.recorder.isRecording)
    #expect(harness.controller.status == .listening)
}

@MainActor
@Test("A press refused for a meeting while the last result is showing still flashes busy (F443)")
func meetingRefusalAfterAResultFlashesBusy() async throws {
    let harness = try Harness(engine: FailingDictationEngine())
    defer { harness.cleanup() }
    try await harness.dictateOnce()
    // A meeting started inside the failure's dismiss window, which nothing prevents: a failed
    // dictation is not `isActive`, so the meeting guard does not wait for its pill.
    harness.controller.configure(isMicrophoneBusy: { true })

    harness.monitor.onPressStart?()

    #expect(!harness.recorder.isRecording)
    #expect(harness.overlay.phases.last == .busy)
}

@MainActor
@Test("A press while a dictation is still transcribing flashes busy and keeps the transcript (F443)")
func pressWhileTranscribingFlashesBusy() async throws {
    let engine = GatedDictationEngine()
    let harness = try Harness(engine: engine)
    defer { harness.cleanup() }
    harness.monitor.onPressStart?()
    harness.monitor.onPressEnd?()
    try #require(harness.controller.status == .transcribing)

    harness.monitor.onPressStart?()

    #expect(!harness.recorder.isRecording)
    #expect(harness.controller.status == .transcribing)
    #expect(harness.overlay.phases.last == .busy)
    #expect(harness.monitor.resetToggleCount > 0)

    // The flash is brief, and the pill goes back to saying what is still happening.
    for _ in 0..<300 where harness.overlay.phases.last == .busy {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(harness.overlay.phases.last == .transcribing)

    // The refused press must not have dropped the transcript that was in flight.
    engine.openGate()
    for _ in 0..<1_000 where harness.controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let entry = try #require(harness.controller.logStore.log.entries.first)
    #expect(entry.text == "held transcript")
}
