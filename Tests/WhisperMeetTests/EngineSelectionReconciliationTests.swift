import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F262 — the app wiring for engine/runtime reconciliation.
//
// `TranscriptionEngineAvailabilityTests` covers the rules; this covers that `AppModel` actually
// asks them. Without this the pure core would be an unreachable library, which AGENTS.md's
// reachability rule exists to prevent.

@MainActor
private func makeModel(
    suite: String,
    storedEngine: String? = nil,
    whisperInstalled: Bool,
    qwenInstalled: Bool
) -> (AppModel, UserDefaults, String) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    if let storedEngine {
        defaults.set(storedEngine, forKey: "localWhisperModel")
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngineSelectionReconciliationTests-\(UUID().uuidString)")
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { whisperInstalled ? URL(fileURLWithPath: "/tmp/whisper") : nil },
        qwenInstalled: { qwenInstalled }
    )
    return (model, defaults, suite)
}

@MainActor
@Test("A Qwen-only Mac with no stored choice selects Qwen and can transcribe (F262)")
func qwenOnlyMacSelectsQwen() {
    let (model, defaults, suite) = makeModel(
        suite: "F262.qwenOnly", whisperInstalled: false, qwenInstalled: true
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    // This is the whole user-reported bug: before F262 this was `.whisperLarge`, and
    // `isSelectedEngineInstalled` was false forever.
    #expect(model.selectedEngine == .qwenBalanced)
    #expect(model.isSelectedEngineInstalled)
    #expect(model.transcriptionUnavailableMessage == nil)
}

@MainActor
@Test("A Whisper-only Mac with no stored choice still selects Whisper Large (F262)")
func whisperOnlyMacSelectsWhisper() {
    let (model, defaults, suite) = makeModel(
        suite: "F262.whisperOnly", whisperInstalled: true, qwenInstalled: false
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(model.selectedEngine == .whisperLarge)
    #expect(model.isSelectedEngineInstalled)
}

@MainActor
@Test("A stored choice survives launch even when that engine is missing (F262)")
func storedChoiceIsNotOverwritten() {
    let (model, defaults, suite) = makeModel(
        suite: "F262.storedTurbo",
        storedEngine: "turbo",
        whisperInstalled: false,
        qwenInstalled: true
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    // Switching for them would be persisted by `selectedEngine`'s didSet — destroying the choice on
    // disk, not just for this launch. So it stands, and the message does the work instead.
    #expect(model.selectedEngine == .whisperTurbo)
    #expect(!model.isSelectedEngineInstalled)
    #expect(defaults.string(forKey: "localWhisperModel") == "turbo")
}

@MainActor
@Test("The refusal names the installed engine rather than 'the selected model' (F262)")
func refusalNamesTheInstalledEngine() {
    let (model, defaults, suite) = makeModel(
        suite: "F262.message",
        storedEngine: "large",
        whisperInstalled: false,
        qwenInstalled: true
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    let message = model.transcriptionUnavailableMessage
    #expect(message != nil)
    #expect(message?.contains("Qwen3-ASR") == true, "it must name the engine that IS installed")
    #expect(message?.contains("Whisper Large") == true)
    // The old copy, which is what made this bug confusing rather than merely blocking.
    #expect(message?.contains("Install the selected transcription model") == false)
}

@MainActor
@Test("With nothing installed the message offers no phantom alternative (F262)")
func nothingInstalledMessage() {
    let (model, defaults, suite) = makeModel(
        suite: "F262.none", whisperInstalled: false, qwenInstalled: false
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(model.transcriptionUnavailableMessage != nil)
    #expect(model.transcriptionUnavailableMessage?.contains("Qwen3-ASR") == false)
}
