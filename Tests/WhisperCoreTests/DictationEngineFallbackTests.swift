import Testing
import Foundation
@testable import WhisperCore

private struct StubError: Error {}

private final class StubDictationEngine: DictationEngine, @unchecked Sendable {
    let label: String
    let warmError: Error?
    private(set) var warmed = false
    private(set) var transcribeCount = 0

    init(label: String, warmError: Error? = nil) {
        self.label = label
        self.warmError = warmError
    }

    func warmUp() async throws {
        if let warmError { throw warmError }
        warmed = true
    }

    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        transcribeCount += 1
        return DictationResult(text: label, languageCode: nil)
    }

    func shutdown() {}
}

@Test("Fallback engine uses the primary when it warms up")
func fallbackUsesPrimaryWhenAvailable() async throws {
    let primary = StubDictationEngine(label: "primary")
    let fallback = StubDictationEngine(label: "fallback")
    let engine = FallbackDictationEngine(primary: primary, fallback: fallback)

    try await engine.warmUp()
    let result = try await engine.transcribe(
        wavAt: URL(fileURLWithPath: "/tmp/x.wav"), language: .automatic, initialPrompt: nil)

    #expect(result.text == "primary")
    #expect(fallback.transcribeCount == 0)
}

@Test("Fallback engine switches to the fallback when the primary can't warm up")
func fallbackUsedWhenPrimaryFails() async throws {
    let primary = StubDictationEngine(label: "primary", warmError: StubError())
    let fallback = StubDictationEngine(label: "fallback")
    let engine = FallbackDictationEngine(primary: primary, fallback: fallback)

    try await engine.warmUp()
    let result = try await engine.transcribe(
        wavAt: URL(fileURLWithPath: "/tmp/x.wav"), language: .automatic, initialPrompt: nil)

    #expect(result.text == "fallback")
    #expect(fallback.warmed)
}

@Test("Fallback engine warms up on demand when transcribe is called before warmUp")
func fallbackWarmsOnDemand() async throws {
    let primary = StubDictationEngine(label: "primary", warmError: StubError())
    let fallback = StubDictationEngine(label: "fallback")
    let engine = FallbackDictationEngine(primary: primary, fallback: fallback)

    let result = try await engine.transcribe(
        wavAt: URL(fileURLWithPath: "/tmp/x.wav"), language: .automatic, initialPrompt: nil)

    #expect(result.text == "fallback")
}
