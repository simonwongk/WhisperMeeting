import Foundation
import Testing
@testable import WhisperCore

@Test("Dictation offers Turbo and Qwen without silently enabling unsupported prompts")
func dictationModelCapabilitiesAreExplicit() {
    #expect(DictationTranscriptionEngine.whisperTurbo.supportsVocabularyPrompt)
    #expect(!DictationTranscriptionEngine.qwenBalanced.supportsVocabularyPrompt)
    #expect(DictationTranscriptionEngine.whisperTurbo.rawValue == "turbo")
    #expect(DictationTranscriptionEngine.qwenBalanced.rawValue == "qwen3-asr-1.7b-8bit")
    #expect(DictationTranscriptionEngine.availableCases.first == .whisperTurbo)
}

@Test("Replacing the selected dictation model shuts down the resident model")
func replacingDictationEngineReleasesPreviousModel() async throws {
    let firstState = EngineState(result: "first")
    let secondState = EngineState(result: "second")
    let selected = SelectableDictationEngine(engine: EngineSpy(state: firstState))

    let firstResult = try await selected.transcribe(
        wavAt: URL(fileURLWithPath: "/tmp/shared-capture.wav"),
        language: .automatic,
        initialPrompt: nil
    )
    await selected.replace(with: EngineSpy(state: secondState))
    let secondResult = try await selected.transcribe(
        wavAt: URL(fileURLWithPath: "/tmp/shared-capture.wav"),
        language: .automatic,
        initialPrompt: nil
    )

    #expect(firstResult.text == "first")
    #expect(secondResult.text == "second")
    #expect(firstState.shutdownCount == 1)
    #expect(secondState.shutdownCount == 0)
}

private final class EngineState: @unchecked Sendable {
    let result: String
    private(set) var shutdownCount = 0
    private let lock = NSLock()

    init(result: String) {
        self.result = result
    }

    func recordShutdown() {
        lock.lock()
        shutdownCount += 1
        lock.unlock()
    }
}

private final class EngineSpy: DictationEngine, @unchecked Sendable {
    private let state: EngineState

    init(state: EngineState) {
        self.state = state
    }

    func warmUp() async throws {}

    func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: state.result, languageCode: nil)
    }

    func shutdown() {
        state.recordShutdown()
    }
}
