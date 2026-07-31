import Foundation

/// The menu-bar recording menu's derived presentation: titles, per-item enablement, an SF Symbol,
/// and whether Cancel needs a confirmation. Pure so it is testable without SwiftUI (F62).
public struct MenuBarRecordingPresentation: Sendable, Equatable {
    public let symbol: String
    public let statusTitle: String
    public let startTitle: String
    public let startEnabled: Bool
    public let stopTitle: String
    public let stopEnabled: Bool
    public let addMarkerEnabled: Bool
    public let cancelEnabled: Bool
    public let cancelNeedsConfirmation: Bool
}

public enum MenuBarRecording {
    public static func make(
        isRecording: Bool,
        isStopping: Bool,
        elapsedSeconds: TimeInterval,
        isMicrophoneBusy: Bool,
        hasActiveTranscription: Bool
    ) -> MenuBarRecordingPresentation {
        let recording = isRecording && !isStopping
        let statusTitle: String
        if isStopping {
            statusTitle = "Finishing…"
        } else if isRecording {
            statusTitle = "Recording \(TranscriptFormatter.timestamp(elapsedSeconds))"
        } else if hasActiveTranscription {
            statusTitle = "Transcribing…"
        } else {
            statusTitle = "Not recording"
        }
        return MenuBarRecordingPresentation(
            symbol: recording ? "record.circle.fill" : (isStopping ? "stop.circle" : "record.circle"),
            statusTitle: statusTitle,
            startTitle: "Start Recording",
            startEnabled: !isRecording && !isStopping && !isMicrophoneBusy && !hasActiveTranscription,
            stopTitle: "Stop & Transcribe",
            stopEnabled: recording,
            addMarkerEnabled: recording,
            cancelEnabled: recording,
            cancelNeedsConfirmation: true // Cancel is the only destructive path — always confirm
        )
    }
}
