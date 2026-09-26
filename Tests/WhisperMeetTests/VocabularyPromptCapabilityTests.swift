import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F509 — a Homebrew or pipx `whisper` older than openai-whisper 20250625 is accepted by
// `findExecutable()` with no version check, and `commandArguments` unconditionally adds
// `--carry_initial_prompt` the moment a meeting has any vocabulary term, which such a build
// rejects at argparse. `LocalWhisperRuntimeTests` covers the pure probe; this covers that
// `AppModel` actually asks it and stops sending vocabulary a discovered runtime cannot accept,
// which the reachability rule (AGENTS.md) requires beyond a tested-but-uncalled core.

@MainActor
private func makeModel(
    suite: String,
    supportsCarryInitialPrompt: Bool
) -> (AppModel, UserDefaults, String) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-F509-fixture") },
        qwenInstalled: { false }
    )
    model.checkCarryInitialPromptSupport = { _ in supportsCarryInitialPrompt }
    model.refreshRuntime() // recompute using the seam just assigned, not init's real-probe default
    return (model, defaults, suite)
}

@MainActor
@Test("A capable runtime reports no vocabulary caveat, even with vocabulary present (F509)")
func capableRuntimeReportsNoVocabularyCaveat() {
    let (model, defaults, suite) = makeModel(suite: "F509.capable", supportsCarryInitialPrompt: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    model.store.addVocabulary(["WhisperMeet"])

    #expect(model.runtimeSupportsVocabularyPrompt)
    #expect(model.vocabularyPromptUnsupportedNotice == nil)
}

@MainActor
@Test("An incapable runtime names the fix only once vocabulary would actually be sent (F509)")
func incapableRuntimeNoticeNeedsVocabularyPresent() {
    let (model, defaults, suite) = makeModel(suite: "F509.incapableEmpty", supportsCarryInitialPrompt: false)
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!model.runtimeSupportsVocabularyPrompt)
    // No vocabulary terms yet, so nothing would be omitted — no caveat to show.
    #expect(model.vocabularyPromptUnsupportedNotice == nil)

    model.store.addVocabulary(["Acme Corp"])
    #expect(model.vocabularyPromptUnsupportedNotice != nil)
    #expect(model.vocabularyPromptUnsupportedNotice!.contains("20250625"))
}

@MainActor
@Test("No installed runtime is not itself a vocabulary caveat (F509)")
func missingRuntimeReportsNoVocabularyCaveat() {
    let defaults = UserDefaults(suiteName: "F509.missing")!
    defaults.removePersistentDomain(forName: "F509.missing")
    defer { defaults.removePersistentDomain(forName: "F509.missing") }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { nil },
        qwenInstalled: { false }
    )
    model.store.addVocabulary(["Acme Corp"])

    #expect(model.runtimeSupportsVocabularyPrompt)
    #expect(model.vocabularyPromptUnsupportedNotice == nil)
}
