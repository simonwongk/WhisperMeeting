import Foundation
import WhisperCore

/// What a test's `DictationController` gets in place of a real engine it did not name (F991): every
/// request fails, and no helper is built or started.
struct RefusedDictationEngine: DictationEngine {
    struct Refused: LocalizedError {
        var errorDescription: String? {
            "This dictation controller was built in a test without an engine of its own, so it has none."
        }
    }

    func warmUp() async throws { throw Refused() }
    func touch() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        throw Refused()
    }
    func shutdown() {}
    func evict() async {}
    func retire() async {}
    func observeModelDownload(_ observer: DictationModelDownloadObserver?) {}
    func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {}
}

/// The same for a refiner (F991): never warm, and every attempt hands back the raw text.
struct RefusedDictationRefiner: DictationTextRefining {
    func warmUp() async -> Bool { false }
    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        RefineAttempt(text: text, outcome: .rawError)
    }
    func shutdown() {}
}
