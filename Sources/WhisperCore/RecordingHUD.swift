import Foundation

/// The display state of a compact recording HUD overlay. Pure and framework-free (F74).
public struct RecordingHUDState: Sendable, Equatable {
    public let elapsedText: String
    public let statusLine: String
    public let topWarning: String?
    public let level: Float

    public init(elapsedText: String, statusLine: String, topWarning: String?, level: Float) {
        self.elapsedText = elapsedText
        self.statusLine = statusLine
        self.topWarning = topWarning
        self.level = level
    }
}

public enum RecordingHUD {
    public static func make(
        isRecording: Bool,
        isStopping: Bool,
        elapsedSeconds: TimeInterval,
        health: RecordingHealthSnapshot?,
        level: Float
    ) -> RecordingHUDState {
        RecordingHUDState(
            elapsedText: TranscriptFormatter.clock(elapsedSeconds),
            statusLine: isStopping ? "Finishing…" : "Recording",
            topWarning: health.flatMap { topWarning(from: $0.warnings) },
            level: max(0, min(1, level))
        )
    }

    /// Show the passive HUD only while recording AND the app is backgrounded (in-window panels cover
    /// the foreground case).
    public static func shouldPresent(isRecording: Bool, appIsActive: Bool) -> Bool {
        isRecording && !appIsActive
    }

    /// The single most-severe warning's message, or nil when there are none.
    static func topWarning(from warnings: [RecordingHealthWarning]) -> String? {
        warnings.min(by: { rank($0) < rank($1) }).map(message)
    }

    /// Severity rank (lower = worse). Consistent with `RecordingHealthSnapshot.overallStatus`, which
    /// treats stopped-capture and low storage as at-risk.
    static func rank(_ warning: RecordingHealthWarning) -> Int {
        switch warning {
        case .microphoneCaptureStopped, .systemAudioCaptureStopped: return 0
        // Ranked with low storage (F150): both mean "this recording is about to stop being fully
        // usable and only you can prevent it", and both are fixed the same way — stop and start a
        // new one. Above clipping, which degrades quality; below a dead channel, which is losing
        // audio right now.
        case .lowStorage, .approachingLengthLimit: return 1
        case .systemAudioNotDetected: return 2
        case .microphoneClipping, .systemAudioClipping: return 3
        }
    }

    static func message(_ warning: RecordingHealthWarning) -> String {
        switch warning {
        case .microphoneCaptureStopped: return "Microphone capture stopped"
        case .systemAudioCaptureStopped: return "System audio capture stopped"
        case .lowStorage: return "Low storage — recording may stop soon"
        // States the consequence, not the cause: "the WAV length field overflows" means nothing to
        // anyone, and the action is the same either way.
        case .approachingLengthLimit:
            return "Very long recording — stop soon so the whole file stays readable"
        case .systemAudioNotDetected: return "No system audio detected"
        case .microphoneClipping: return "Microphone is clipping"
        case .systemAudioClipping: return "System audio is clipping"
        }
    }
}
