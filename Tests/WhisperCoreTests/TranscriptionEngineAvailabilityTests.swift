import Foundation
import Testing
@testable import WhisperCore

// F262 — a Mac with only Qwen installed could never start a transcription.
//
// `AppModel` decoded a missing `localWhisperModel` preference to `.whisperLarge`, and
// `isSelectedEngineInstalled` then asked `isRuntimeInstalled` — false forever on a Mac with no
// `whisper` executable. Nothing reconciled the two: `refreshRuntime()` only rewrote booleans, and
// `installQwenASR()` never touched the selection, so the sole escape was finding the Settings
// picker by hand.
//
// Two rules, and the distinction between them is the whole ticket:
//   * No stored preference means the user has not chosen, so choosing an installed engine for them
//     overrides nothing.
//   * A stored preference IS a choice. It is preserved even when that engine is missing, and the
//     refusal names the engine that is actually installed instead of saying "install a model".

@Test("With no stored choice and only Qwen installed, Qwen is selected (F262)")
func initialSelectionPrefersQwenWhenItIsTheOnlyInstalledEngine() {
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: nil,
        isWhisperInstalled: false,
        isQwenInstalled: true,
        isQwenSupported: true
    )
    #expect(engine == .qwenBalanced)
}

@Test("With no stored choice and only Whisper installed, Whisper Large is selected (F262)")
func initialSelectionPrefersWhisperWhenItIsTheOnlyInstalledEngine() {
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: nil,
        isWhisperInstalled: true,
        isQwenInstalled: false,
        isQwenSupported: true
    )
    #expect(engine == .whisperLarge)
}

@Test("With no stored choice and both installed, Whisper Large remains the documented default (F262)")
func initialSelectionKeepsWhisperDefaultWhenBothAreInstalled() {
    // PRODUCT_SPEC and the Settings copy both say Whisper Large is the default and Qwen is opt-in.
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: nil,
        isWhisperInstalled: true,
        isQwenInstalled: true,
        isQwenSupported: true
    )
    #expect(engine == .whisperLarge)
}

@Test("With nothing installed the default is unchanged (F262)")
func initialSelectionFallsBackToWhisperWhenNothingIsInstalled() {
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: nil,
        isWhisperInstalled: false,
        isQwenInstalled: false,
        isQwenSupported: true
    )
    #expect(engine == .whisperLarge)
}

@Test("A deliberate stored choice is never overridden, even when it is not installed (F262)")
func initialSelectionPreservesAStoredChoice() {
    // Silently switching would be persisted by AppModel's `didSet` — destroying the user's choice.
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: .whisperTurbo,
        isWhisperInstalled: false,
        isQwenInstalled: true,
        isQwenSupported: true
    )
    #expect(engine == .whisperTurbo)
}

@Test("A stored Qwen choice on a Mac that cannot run it falls back to an installed engine (F262)")
func initialSelectionDropsAnUnsupportedStoredChoice() {
    // `isSupportedOnCurrentMac` is compile-time arch; on non-arm64 a stored Qwen choice is unusable.
    let engine = TranscriptionEngineAvailability.initialSelection(
        stored: .qwenBalanced,
        isWhisperInstalled: true,
        isQwenInstalled: false,
        isQwenSupported: false
    )
    #expect(engine == .whisperLarge)
}

@Test("No message when the selected engine is installed (F262)")
func noMessageWhenSelectedEngineIsInstalled() {
    #expect(TranscriptionEngineAvailability.unavailableMessage(
        selected: .qwenBalanced, isWhisperInstalled: false, isQwenInstalled: true
    ) == nil)
    #expect(TranscriptionEngineAvailability.unavailableMessage(
        selected: .whisperLarge, isWhisperInstalled: true, isQwenInstalled: false
    ) == nil)
}

@Test("The refusal names the engine that IS installed, not just 'a model' (F262)")
func messageNamesTheInstalledEngine() {
    let message = TranscriptionEngineAvailability.unavailableMessage(
        selected: .whisperLarge, isWhisperInstalled: false, isQwenInstalled: true
    )
    // The old copy said only "Install the selected transcription model in Settings", which reads as
    // false to someone who has just installed Qwen. It must name both sides of the mismatch.
    #expect(message != nil)
    #expect(message?.contains("Whisper Large") == true)
    #expect(message?.contains("Qwen3-ASR") == true)
    #expect(message?.contains("Settings") == true)
}

@Test("The mirrored case names Whisper when Qwen is selected but missing (F262)")
func messageNamesWhisperWhenQwenIsMissing() {
    let message = TranscriptionEngineAvailability.unavailableMessage(
        selected: .qwenBalanced, isWhisperInstalled: true, isQwenInstalled: false
    )
    #expect(message?.contains("Qwen3-ASR") == true)
    #expect(message?.contains("Whisper Large") == true)
}

@Test("With nothing installed the message asks for an install, naming no alternative (F262)")
func messageAsksForAnInstallWhenNothingIsAvailable() {
    let message = TranscriptionEngineAvailability.unavailableMessage(
        selected: .whisperLarge, isWhisperInstalled: false, isQwenInstalled: false
    )
    #expect(message != nil)
    #expect(message?.contains("Qwen3-ASR") == false, "there is no installed alternative to offer")
    #expect(message?.contains("Settings") == true)
}

@Test("Every engine has a short name fit for a sentence (F262)")
func engineShortNames() {
    // `displayName` carries a marketing suffix ("Whisper Large — best-established") that reads badly
    // mid-sentence, so the messages above need a bare name.
    #expect(MeetingTranscriptionEngine.whisperLarge.shortDisplayName == "Whisper Large")
    #expect(MeetingTranscriptionEngine.whisperTurbo.shortDisplayName == "Whisper Turbo")
    #expect(MeetingTranscriptionEngine.qwenBalanced.shortDisplayName == "Qwen3-ASR")
    for engine in MeetingTranscriptionEngine.allCases {
        #expect(!engine.shortDisplayName.contains("—"))
    }
}
