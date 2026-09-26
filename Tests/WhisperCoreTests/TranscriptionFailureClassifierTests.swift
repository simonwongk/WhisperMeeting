import Foundation
import Testing
@testable import WhisperCore

private struct UnknownError: Error {}

/// F68 — transcription failures map to a single actionable category, not a blind retry.
@Test("Transcription failures classify into actionable categories")
func classifiesTranscriptionFailures() {
    // Runtime missing → install (for both engine error types).
    #expect(TranscriptionFailureClassifier.classify(QwenASRError.runtimeNotInstalled).action == .installRuntime)
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.runtimeNotInstalled).action == .installRuntime)

    // Missing audio → re-import (retrying as-is fails again). No speech is not missing audio (F561).
    #expect(TranscriptionFailureClassifier.classify(QwenASRError.recordingNotFound).action == .reimport)
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.recordingNotFound).action == .reimport)

    // Transient subprocess failures → retry.
    #expect(TranscriptionFailureClassifier.classify(QwenASRError.processFailed("boom")).action == .retry)
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.missingOutput).action == .retry)

    // Cancellation is not a failure to act on.
    #expect(TranscriptionFailureClassifier.classify(CancellationError()).action == .none)

    // An unrecognized error defaults to retry.
    #expect(TranscriptionFailureClassifier.classify(UnknownError()).action == .retry)
}

/// F118 — a Qwen "unsupported file format" failure is deterministic (the container can't be decoded
/// by this engine), so the classifier must guide switching engines rather than a retry that can never
/// succeed with the same engine.
@Test("A Qwen unsupported-format failure suggests switching engines, not retrying (F118)")
func qwenUnsupportedFormatSuggestsEngineSwitch() {
    let stderr = "Traceback (most recent call last):\n"
        + "  File \"qwen_transcribe.py\", line 126, in <module>\n"
        + "miniaudio.DecodeError: unsupported file format"
    let category = TranscriptionFailureClassifier.classify(QwenASRError.processFailed(stderr))
    #expect(category.action == .switchEngine)
    // The deterministic "try transcribing again" advice must be gone…
    #expect(!category.explanation.contains("try transcribing again"))
    // …replaced by guidance to use the other engine, which decodes more formats.
    #expect(category.explanation.contains("Whisper"))
}

/// F561 — both engines raise `.emptyTranscript` when recognition returns no text: a muted or wrong
/// microphone, a silent meeting. That was classified `.reimport`, so the meeting said "No usable audio
/// was found … Re-import the recording", which names the wrong cause and, for a live capture, advice
/// that cannot be followed. And because only `.retry` keeps the underlying detail, the engine's own
/// "No speech was detected" never reached the user.
@Test("No speech detected says so and points at the microphone, not at re-importing (F561)")
func emptyTranscriptIsReportedAsNoSpeech() {
    for error in [LocalWhisperError.emptyTranscript as Error, QwenASRError.emptyTranscript as Error] {
        let category = TranscriptionFailureClassifier.classify(error)
        #expect(category.action != .reimport)
        #expect(category.action != .retry) // the same audio will come back empty again
        #expect(category.explanation.contains("No speech was detected"))
        #expect(category.explanation.contains("microphone"))
        #expect(category.explanation.contains("unchanged"))
        #expect(!category.explanation.contains("Re-import"))
    }
    // A missing recording still gets the re-import advice.
    let missing = TranscriptionFailureClassifier.classify(LocalWhisperError.recordingNotFound)
    #expect(missing.explanation.contains("Re-import"))
}
