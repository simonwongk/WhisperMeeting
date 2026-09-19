import Foundation

/// The menu-bar recording menu's derived presentation: titles, per-item enablement, an SF Symbol,
/// and whether Cancel needs a confirmation. Pure so it is testable without SwiftUI (F62).
public struct MenuBarRecordingPresentation: Sendable, Equatable {
    public let symbol: String
    public let statusTitle: String
    /// The recording's worst live health problem, or nil when healthy or not recording (F294).
    public let healthLine: String?
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
        hasActiveTranscription: Bool,
        health: RecordingHealthSnapshot? = nil
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
        // F294: the health banner was window-only, so a menu-bar recording could lose a channel
        // unseen. Only a live recording's health counts — a snapshot outliving its recording is stale.
        let liveHealth = recording ? health : nil
        let atRisk = liveHealth?.overallStatus == .atRisk
        let healthLine = liveHealth.flatMap { RecordingHUD.topWarning(from: $0.warnings) }
            .map { atRisk ? "⚠︎ \($0)" : $0 }
        return MenuBarRecordingPresentation(
            symbol: atRisk
                ? "exclamationmark.triangle.fill"
                : recording ? "record.circle.fill" : (isStopping ? "stop.circle" : "record.circle"),
            statusTitle: statusTitle,
            healthLine: healthLine,
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

/// Decides when a recording's health is worth interrupting someone for (F294).
///
/// The health tick is 1 Hz, so posting whenever a snapshot is at risk would post sixty notifications
/// a minute. Each at-risk problem is announced once per recording — including when it clears and
/// returns, because a flapping stream would otherwise do the same thing more slowly. Cautions
/// (clipping, quiet system audio) are never announced: they degrade a recording, they do not lose it.
public struct RecordingRiskAnnouncer: Sendable {
    private var announced: Set<RecordingHealthWarning> = []

    public init() {}

    /// Forgets what was announced, after the capture recovered (F292): a second outage in the same
    /// recording is new information, and the restart bound keeps a flapping capture from repeating
    /// it more than a few times.
    public mutating func rearm() {
        rearmWhenClear = true
    }

    /// Set by `rearm()`; the next snapshot with no at-risk warning clears what was announced. Not
    /// cleared at once: the health monitor's staleness is measured from the last sample, so the
    /// ticks straight after a restart still show the old outage, and re-arming then would announce
    /// "needs attention" right after "resumed" (F292 review).
    private var rearmWhenClear = false

    /// The message to deliver for `snapshot`, or nil when there is nothing new to say.
    public mutating func announcement(for snapshot: RecordingHealthSnapshot) -> String? {
        if rearmWhenClear, snapshot.overallStatus != .atRisk {
            announced.removeAll()
            rearmWhenClear = false
        }
        let fresh = snapshot.warnings.filter { warning in
            RecordingHealthSnapshot(
                microphoneLevel: snapshot.microphoneLevel, systemAudioLevel: snapshot.systemAudioLevel,
                availableStorageBytes: nil, warnings: [warning]
            ).overallStatus == .atRisk && !announced.contains(warning)
        }
        guard let worst = fresh.min(by: { RecordingHUD.rank($0) < RecordingHUD.rank($1) }) else { return nil }
        // Only the one announced is marked, so a second problem hidden behind it still gets its turn.
        announced.insert(worst)
        return "Recording needs attention: \(RecordingHUD.message(worst))."
    }
}
