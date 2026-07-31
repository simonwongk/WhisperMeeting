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

    // Missing / empty audio → re-import (retrying as-is fails again).
    #expect(TranscriptionFailureClassifier.classify(QwenASRError.emptyTranscript).action == .reimport)
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.recordingNotFound).action == .reimport)

    // Transient subprocess failures → retry.
    #expect(TranscriptionFailureClassifier.classify(QwenASRError.processFailed("boom")).action == .retry)
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.missingOutput).action == .retry)

    // Cancellation is not a failure to act on.
    #expect(TranscriptionFailureClassifier.classify(CancellationError()).action == .none)

    // An unrecognized error defaults to retry.
    #expect(TranscriptionFailureClassifier.classify(UnknownError()).action == .retry)
}
