import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F537 part 1 — Quick Dictation's outcomes were only a pill that never becomes key and hides after
/// a second, which VoiceOver does not read: a refused press, a failure, "nothing heard" and a
/// delivery were all silent for a VoiceOver user. Each is now announced once through the
/// controller's `announce` seam, which the app posts as an accessibility announcement. Progress
/// ("Listening…", "Transcribing…") is not announced: speech during a capture would be recorded.

@MainActor
private final class PhaseLog: DictationOverlayPresenting {
    private(set) var shown: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { shown.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

/// Holds a transcription until the test lets it finish, so a dictation can be kept in
/// "Transcribing…" without a clock.
private final class HeldEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    var isHolding: Bool { lock.withLock { waiting != nil } }

    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return DictationResult(text: "dictated words", languageCode: "en")
    }
    func shutdown() {}

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let recorder: FakeDictationRecorder
    let overlay: PhaseLog
    let engine: HeldEngine
    let cleanUp: () -> Void
    /// Everything the controller asked to be announced, in order.
    var announced: [String] { box.lines }
    private let box: AnnouncementBox

    init() throws {
        let suite = "WhisperMeet.DictationAnnouncementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationAnnouncementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        let monitor = FakeHotkeyMonitor()
        let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
        let overlay = PhaseLog()
        let engine = HeldEngine()
        let box = AnnouncementBox()
        self.monitor = monitor
        self.recorder = recorder
        self.overlay = overlay
        self.engine = engine
        self.box = box
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
        controller.announce = { box.lines.append($0) }
    }
}

@MainActor
private final class AnnouncementBox {
    var lines: [String] = []
}

/// Polls the value asserted after it; 30 s is far past any host.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
@Test("A refused press is announced, once however many presses land during the flash (F537)")
func aRefusedPressIsAnnouncedOnce() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    harness.controller.configure(isMicrophoneBusy: { true })

    harness.monitor.onPressStart?()
    harness.monitor.onPressStart?()

    let busy = try #require(DictationController.announcement(for: .busy))
    #expect(harness.announced == [busy], "a refused press was silent, or said more than once")
}

@MainActor
@Test("A failed dictation is announced with its reason (F537)")
func aFailureIsAnnouncedWithItsReason() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    harness.monitor.onPressStart?()
    try #require(harness.controller.status == .listening)
    #expect(harness.announced.isEmpty, "the start of a capture was announced into the microphone")

    let reason = DictationCaptureInterruption.deviceConfigurationChanged
    harness.recorder.simulateCaptureInterruption(reason)
    let failed = try await waitUntil { if case .error = harness.controller.status { true } else { false } }
    try #require(failed, "the interruption never failed the dictation")

    #expect(harness.announced.count == 1)
    #expect(harness.announced.first?.contains(reason.message) == true, "the failure was announced without its reason")
}

@MainActor
@Test("A dictation that heard nothing is announced (F537)")
func nothingHeardIsAnnounced() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    harness.recorder.stopError = MicDictationRecorder.RecorderError.noAudioCaptured

    harness.monitor.onPressStart?()
    harness.monitor.onPressEnd?()

    let empty = try #require(DictationController.announcement(for: .empty))
    #expect(harness.announced == [empty])
}

/// "Transcribing…" is progress, not an outcome; a busy flash over it puts that pill back, and
/// putting it back must not announce anything either. Then the delivery is announced.
@MainActor
@Test("A delivery is announced once; progress and the pill a busy flash restores are not (F537)")
func aDeliveryIsAnnouncedAndProgressIsNot() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let (controller, overlay) = (harness.controller, harness.overlay)

    harness.monitor.onPressStart?()
    harness.monitor.onPressEnd?()
    try #require(controller.status == .transcribing)
    let holding = try await waitUntil { harness.engine.isHolding }
    try #require(holding)
    #expect(harness.announced.isEmpty, "progress was announced")

    // A press while that dictation is in flight is refused with a flash, which then hands the pill
    // back to "Transcribing…".
    harness.monitor.onPressStart?()
    let busy = try #require(DictationController.announcement(for: .busy))
    #expect(harness.announced == [busy])
    let restored = try await waitUntil { overlay.shown.filter { $0 == .transcribing }.count == 2 }
    try #require(restored, "the flash never handed the pill back")
    #expect(harness.announced == [busy], "the pill the flash restored was announced again")

    harness.engine.release()
    let delivered = try await waitUntil { overlay.shown.last == .copied }
    try #require(delivered, "the dictation was not delivered")
    let copied = try #require(DictationController.announcement(for: .copied))
    #expect(harness.announced == [busy, copied])
}
