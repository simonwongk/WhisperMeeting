import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F827 — a first-run model download that stalled or failed used to be swallowed by
/// `FallbackDictationEngine` (and, at warm-up time with no press, only logged). The engine now throws
/// `DictationModelDownloadError`; these pin what the CONTROLLER does with it: the message reaches the
/// user's history (the one place the app shows why a dictation failed) and the pill, both when a
/// press's transcription hits it and when the warm-up alone does.

private let downloadStallMessage =
    "The dictation model download made no progress for 180 seconds and was stopped. "
    + "Check your connection and try again; a download continues from where it stopped when it can."

/// A warm engine whose model cannot be downloaded: every warm-up and transcription throws the
/// download error, as `FallbackDictationEngine` now lets it.
private final class DownloadStalledEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _warmUps = 0
    var warmUpCount: Int { lock.withLock { _warmUps } }

    func warmUp() async throws {
        lock.withLock { _warmUps += 1 }
        throw DictationModelDownloadError(downloadStallMessage)
    }

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        try await warmUp()
        return DictationResult(text: "", languageCode: nil)
    }

    func shutdown() {}
}

/// Remembers every phase the pill was asked to show, since `status` and the pill both clear again
/// after a moment and a test should not race that.
@MainActor
private final class PhaseRecordingOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    var onCopy: (() -> Void)?
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private func makeController(
    engine: DictationEngine,
    overlay: PhaseRecordingOverlay,
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
        overlay: overlay,
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    return (controller, monitor)
}

/// Polls the persisted history (the subject) under a 30 s wall-clock cap and requires it.
@MainActor
private func failedEntry(in directory: URL) async throws -> String {
    var ticks = 0
    var found: String?
    while found == nil, ticks < 6_000 {
        if case .failed(let message)? = DictationLogStore(directory: directory).log.entries.first?.outcome {
            found = message
        } else {
            try await Task.sleep(nanoseconds: 5_000_000)
            ticks += 1
        }
    }
    return try #require(found, "no failed entry reached the history")
}

@MainActor
@Test("A warm-up that cannot download the model tells the user, with the helper's own sentence (F827)")
func warmUpDownloadFailureReachesTheUser() async throws {
    let suite = "WhisperMeet.DictationModelDownloadSurface.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationModelDownloadSurface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = DownloadStalledEngine()
    let overlay = PhaseRecordingOverlay()
    let (controller, _) = makeController(engine: engine, overlay: overlay, defaults: defaults, directory: directory)

    controller.warmUpIfNeeded() // launch, enabling, or a press's prewarm — no dictation in flight

    let recorded = try await failedEntry(in: directory)
    #expect(recorded == downloadStallMessage)
    #expect(overlay.phases.contains(.error), "the pill never showed the failure: \(overlay.phases)")
    #expect(engine.warmUpCount == 1)
}

@MainActor
@Test("A dictation whose transcription hits the stalled download records that sentence (F827)")
func transcriptionDownloadFailureIsRecordedWithItsSentence() async throws {
    let suite = "WhisperMeet.DictationModelDownloadSurface.press.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationModelDownloadSurface-press-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = DownloadStalledEngine()
    let overlay = PhaseRecordingOverlay()
    let (controller, monitor) = makeController(engine: engine, overlay: overlay, defaults: defaults, directory: directory)

    monitor.onPressStart?()
    try #require(controller.status == .listening)
    monitor.onPressEnd?()

    let recorded = try await failedEntry(in: directory)
    #expect(recorded == downloadStallMessage)
    #expect(overlay.phases.contains(.error))
}

@MainActor
@Test("The next press after a download failure starts a dictation instead of staying failed (F827)")
func nextPressAfterADownloadFailureStartsListening() async throws {
    let suite = "WhisperMeet.DictationModelDownloadSurface.retry.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationModelDownloadSurface-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = DownloadStalledEngine()
    let overlay = PhaseRecordingOverlay()
    let (controller, monitor) = makeController(engine: engine, overlay: overlay, defaults: defaults, directory: directory)

    controller.warmUpIfNeeded()
    _ = try await failedEntry(in: directory)
    monitor.onPressStart?()

    #expect(controller.status == .listening, "a failed download must not block the press that retries it")
}
