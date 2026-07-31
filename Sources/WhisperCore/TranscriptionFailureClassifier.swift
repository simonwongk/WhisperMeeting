import Foundation

/// What the user should do about a failed transcription. Drives which single action the detail view
/// offers instead of a blind "Transcribe" retry.
public enum SuggestedAction: Sendable, Equatable {
    case installRuntime  // the runtime is missing — install it first
    case reimport        // the audio is missing/empty/too short — retrying will fail again
    case retry           // a transient/subprocess failure — retrying may succeed
    case none            // cancellation — not a failure the user needs to act on
}

/// A classified transcription failure: a plain-language explanation plus the suggested next action.
public struct FailureCategory: Sendable, Equatable {
    public let action: SuggestedAction
    public let explanation: String

    public init(action: SuggestedAction, explanation: String) {
        self.action = action
        self.explanation = explanation
    }
}

/// Pure mapping from a WhisperCore transcription error to an actionable `FailureCategory`, so the UI
/// can distinguish "install the runtime" from "re-import the audio" from "retry" rather than inviting
/// a blind re-run (F68). Deterministic; no audio access, no language logic; classifies an existing
/// failure only. Distinct from F30 (which is about surfacing alignment warnings).
public enum TranscriptionFailureClassifier {
    public static func classify(_ error: Error) -> FailureCategory {
        if error is CancellationError {
            return FailureCategory(
                action: .none,
                explanation: "Transcription was cancelled. Nothing was changed."
            )
        }
        switch action(for: error) {
        case .installRuntime:
            return FailureCategory(
                action: .installRuntime,
                explanation: "The transcription runtime is not installed. Install it in Settings, then transcribe again."
            )
        case .reimport:
            return FailureCategory(
                action: .reimport,
                explanation: "No usable audio was found for this meeting. Re-import the recording — retrying as-is will fail again."
            )
        case .retry, .none:
            return FailureCategory(
                action: .retry,
                explanation: "Transcription failed partway through. The recording is untouched — try transcribing again."
            )
        }
    }

    private static func action(for error: Error) -> SuggestedAction {
        if let error = error as? LocalWhisperError {
            switch error {
            case .runtimeNotInstalled: return .installRuntime
            case .recordingNotFound, .emptyTranscript: return .reimport
            case .processFailed, .missingOutput, .unreadableOutput: return .retry
            }
        }
        if let error = error as? QwenASRError {
            switch error {
            case .runtimeNotInstalled: return .installRuntime
            case .recordingNotFound, .emptyTranscript: return .reimport
            case .processFailed, .missingOutput, .unreadableOutput: return .retry
            }
        }
        // Unrecognized error → retry is the safest default (never claims the audio is unusable).
        // Categories such as insufficientStorage / audioTooShort become reachable only if those
        // error cases are introduced into the client error types.
        return .retry
    }
}
