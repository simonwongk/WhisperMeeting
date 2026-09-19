import Foundation

/// The menu-bar recording menu's derived presentation: titles, per-item enablement, an SF Symbol,
/// and whether Cancel needs a confirmation. Pure so it is testable without SwiftUI (F62).
public struct MenuBarRecordingPresentation: Sendable, Equatable {
    /// Whether this recording's health is bad enough to change the menu-bar icon (F337).
    ///
    /// Not a symbol name. It used to be one, and nothing read it: `MenuBarExtra`'s icon is built in
    /// `AppEntry.menuBarSymbol`, which re-implemented the rule as `isRecordingActive && health ==
    /// .atRisk` — true for `.starting` and `.stopping` too. So while the app said "Finishing…" and
    /// this very presentation had already suppressed its own health line as stale, the icon still
    /// showed the warning triangle from the last snapshot, and the test asserting the symbol could
    /// not notice because it tested a field nothing displayed. One rule, `isAtRisk`, both places.
    public let isAtRisk: Bool
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
    /// Whether a recording's health should change the menu-bar icon (F337).
    ///
    /// `isRecording && !isStopping` is the load-bearing half: the health tick stops when the
    /// recording does, so a snapshot that outlives its recording is stale, and "Finishing…" is
    /// exactly when a dying capture's last snapshot is still sitting in `recordingHealth`.
    public static func isAtRisk(
        isRecording: Bool,
        isStopping: Bool,
        health: RecordingHealthSnapshot?
    ) -> Bool {
        isRecording && !isStopping && health?.overallStatus == .atRisk
    }

    public static func make(
        isRecording: Bool,
        isStopping: Bool,
        elapsedSeconds: TimeInterval,
        isMicrophoneBusy: Bool,
        hasActiveTranscription: Bool,
        health: RecordingHealthSnapshot? = nil
    ) -> MenuBarRecordingPresentation {
        let recording = isRecording && !isStopping
        let atRisk = Self.isAtRisk(isRecording: isRecording, isStopping: isStopping, health: health)
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
        let healthLine = liveHealth.flatMap { RecordingHUD.topWarning(from: $0.warnings) }
            .map { atRisk ? "⚠︎ \($0)" : $0 }
        return MenuBarRecordingPresentation(
            isAtRisk: atRisk,
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
        // Sets `rearmWhenClear`, declared just below — see its note for why this is not an
        // immediate `announced.removeAll()`.
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
        let fresh = snapshot.warnings.filter { $0.isAtRisk && !announced.contains($0) }
        guard let worst = fresh.min(by: { RecordingHUD.rank($0) < RecordingHUD.rank($1) }) else { return nil }
        // Only the one announced is marked, so a second problem hidden behind it still gets its turn.
        announced.insert(worst)
        return "Recording needs attention: \(RecordingHUD.message(worst))."
    }
}
