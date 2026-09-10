import Foundation
import WhisperCore
@testable import WhisperMeet

/// Shared headless fakes for `DictationController` tests. They exercise the controller's injected
/// seams (recorder, overlay, hotkey monitor, engine) without touching microphone/Accessibility
/// hardware, a real CGEventTap, or a real transcription model.

final class FakeDictationRecorder: DictationRecording {
    private(set) var isRecording = false
    private(set) var stopCount = 0
    var startError: Error?
    /// Duration reported by `stop()`. Default 1 s (transcribe path). Set below the session's
    /// `minClipDuration` (0.35 s) to exercise the immediate discard-to-idle path.
    var stopDuration: TimeInterval = 1
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func requestPermission() async -> Bool { true }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        isRecording = false
        return (outputURL, stopDuration)
    }

    func cancel() {
        isRecording = false
    }
}

@MainActor
final class SilentDictationOverlay: DictationOverlayPresenting {
    func show(_ phase: DictationOverlay.Phase) {}
    func update(level: Float) {}
    func hide() {}
}

struct EmptyDictationEngine: DictationEngine {
    func warmUp() async throws {}

    func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }

    func shutdown() {}
}

/// Counts calls and returns a scripted attempt so wiring tests can drive every refine outcome
/// without a model. Lock-guarded: the controller calls it from a background Task.
final class FakeRefiner: DictationTextRefining, @unchecked Sendable {
    private let lock = NSLock()
    private var _attemptCount = 0
    private var _warmUpCount = 0
    private var _shutdownCount = 0
    private var _scripted: RefineAttempt?
    var attemptCount: Int { lock.withLock { _attemptCount } }
    var warmUpCount: Int { lock.withLock { _warmUpCount } }
    var shutdownCount: Int { lock.withLock { _shutdownCount } }

    /// nil → echo the input back as `.skipped`; set to script a specific outcome.
    func script(_ attempt: RefineAttempt?) { lock.withLock { _scripted = attempt } }

    func warmUp() async -> Bool {
        lock.withLock { _warmUpCount += 1 }
        return true
    }
    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        lock.withLock { _attemptCount += 1 }
        return lock.withLock { _scripted } ?? RefineAttempt(text: text, outcome: .skipped)
    }
    func shutdown() { lock.withLock { _shutdownCount += 1 } }
}

/// Counts `warmUp()` calls so tests can pin exactly when the controller prewarms the
/// transcription engine (F202). Lock-guarded: the controller warms from a background Task.
final class WarmUpCountingEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _warmUpCount = 0
    private var _transcribeCount = 0
    var warmUpCount: Int { lock.withLock { _warmUpCount } }
    var transcribeCount: Int { lock.withLock { _transcribeCount } }
    func warmUp() async throws { lock.withLock { _warmUpCount += 1 } }
    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        lock.withLock { _transcribeCount += 1 }
        return DictationResult(text: "hello", languageCode: "en")
    }
    func shutdown() {}
}

/// A dictation engine that returns a fixed transcript, for refine wiring tests.
struct FixedTextDictationEngine: DictationEngine {
    let text: String
    func warmUp() async throws {}
    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: text, languageCode: "en")
    }
    func shutdown() {}
}

/// A hotkey monitor whose `start()` result is caller-controllable and whose toggle/stop/reset calls
/// are counted, so tests can drive the controller's edge handling deterministically.
final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var startResult = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resetToggleCount = 0

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool {
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
    }

    func resetToggleState() {
        resetToggleCount += 1
    }
}
