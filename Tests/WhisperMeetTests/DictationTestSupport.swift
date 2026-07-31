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
        return (outputURL, 1)
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
