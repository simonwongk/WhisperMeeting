import Foundation

/// Where the speaker-analysis runtime lives on disk, and the policy every runtime is held to
/// (F219/F216). The layout mirrors `QwenASRRuntime`: a self-contained tree under the app's managed
/// Runtime directory, so uninstalling is a single `rm -rf` and a partial install is detectable.
///
/// Deliberately says nothing about *which* runtime is installed. The sherpa-onnx era's path
/// accessors (`executable`, `segmentationModel`, `embeddingModel`, `onnxRuntimeLibrary`,
/// `segmentationLicense`, `manifest`), its `isInstalled` probe, its cosine `clusterThreshold` of
/// 0.40 and its `numThreads` were all removed with that runtime (F216/F219): they named files the
/// installer no longer downloads and flags nothing passes, so they were not merely unused but a
/// second, contradictory answer to "is speaker analysis installed". The real answer is
/// `FluidAudioDiarizationRuntime`, in the app target, compared file-for-file against
/// `Scripts/setup-speaker-diarization.sh`'s manifest by a test.
public struct DiarizationRuntime: Sendable {
    /// Turns below this per-turn confidence are marked `.uncertain` instead of `.speech`.
    ///
    /// Deliberately 0 — the number was not earned. A 0.50 floor does separate wholly-misattributed
    /// turns from correct ones *per turn*, but scored on what a reader actually sees (rows that
    /// survive `SpeakerOverlay`'s 80%/20-point rule) the overlay already abstains on exactly those
    /// rows: 100% displayed precision at 93.3% coverage without the floor, versus 100% at 86.7%
    /// with it. It costs coverage and buys no precision. F225 may revise this only with a
    /// documented before/after table.
    public static let uncertainBelowConfidence = 0.0

    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("Diarization", isDirectory: true)
    }
}

/// One completed analysis. Anonymous by construction: intervals and a count, never a name, an
/// embedding, or anything derived from the transcript (F219).
public struct SpeakerDiarizationResult: Sendable, Equatable {
    public let turns: [SpeakerTurn]
    public let speakerCount: Int
    public let audioSeconds: TimeInterval

    public init(turns: [SpeakerTurn], speakerCount: Int, audioSeconds: TimeInterval) {
        self.turns = turns
        self.speakerCount = speakerCount
        self.audioSeconds = audioSeconds
    }
}

/// Why speaker analysis could not produce turns (F219). Every message ends by saying the transcript
/// is untouched: analysis is an optional extra, and a failure here must never read as data loss.
///
/// The associated values are diagnostics and are never rendered. They can carry a model path or a
/// runtime's own error text, and neither belongs in front of a person.
public enum LocalDiarizationError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case runtimeDamaged(String)
    case audioUnreadable(String)
    case sampleRateMismatch(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            "The speaker-analysis model is not installed. Install it in Settings to analyze speaker turns."
        case .runtimeDamaged:
            "The speaker-analysis model files are missing or damaged. Reinstall it in Settings; your transcript is unchanged."
        case .audioUnreadable:
            "This meeting's recording could not be read for analysis. Your transcript is unchanged."
        case .sampleRateMismatch:
            "The audio prepared for analysis was in the wrong format. Your transcript is unchanged."
        case .processFailed:
            "Speaker analysis did not finish. Your transcript is unchanged."
        }
    }
}
