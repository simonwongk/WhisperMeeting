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

/// When a Start Recording control is enabled — the one rule the record screen's Start button, the
/// menu bar's Start Recording and ⌘R all read (F543).
///
/// Before this each surface had its own: the menu bar greyed Start for the whole of every
/// transcription, which `startRecording()` does not refuse (the record screen and ⌘R both start
/// one then), while ⌘R stayed live through an import, where `startRecording()` returns without a
/// word. Two surfaces for the same action, disagreeing in both directions.
///
/// The inputs are exactly `startRecording()`'s *silent* refusals — not idle, importing, the
/// microphone owned by a preflight test — where an enabled control would be a click that does
/// nothing, plus a recognition-model install, which the record screen already greyed. Refusals that
/// explain themselves (Quick Dictation, a read-only library, low storage, no microphone) leave the
/// control enabled, so the click is answered with the reason rather than a grey item with none.
public enum RecordingStartRule {
    public static func isEnabled(
        isIdle: Bool,
        isImporting: Bool,
        isMicrophoneBusy: Bool,
        isInstallingRecognitionRuntime: Bool
    ) -> Bool {
        isIdle && !isImporting && !isMicrophoneBusy && !isInstallingRecognitionRuntime
    }
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

    /// The line a window shows on every pane while a recording is at risk, or nil (F528).
    ///
    /// Worded like `RecordingRiskAnnouncer`'s notification, so the banner and the notification a
    /// user behind another app got say the same thing, and named from the at-risk warnings only —
    /// the worst warning overall can be a caution ranked beside one (a long recording beside low
    /// storage), and a caution is not what the banner is for.
    public static func riskBannerLine(
        isRecording: Bool,
        isStopping: Bool,
        health: RecordingHealthSnapshot?
    ) -> String? {
        // `leadingWarning`, not a `min(by:)` of its own (F984): a second copy of the selector kept
        // array order on a tie after the shared one stopped doing so for the write failure.
        guard isAtRisk(isRecording: isRecording, isStopping: isStopping, health: health),
              let worst = RecordingHUD.leadingWarning(in: health?.warnings.filter(\.isAtRisk) ?? []) else {
            return nil
        }
        let line = RecordingHUD.message(
            worst, writeFailureCause: health?.writeFailureCause, unsavedTrack: health?.unsavedTrack
        )
        return "Recording needs attention: \(line)."
    }

    /// - Parameter canStartRecording: `RecordingStartRule`'s answer, computed by the caller from the
    ///   same state the record screen's Start button reads (F543). The menu used to derive Start from
    ///   inputs of its own, including a running transcription, and so disagreed with it.
    public static func make(
        isRecording: Bool,
        isStopping: Bool,
        elapsedSeconds: TimeInterval,
        canStartRecording: Bool,
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
        let healthLine = liveHealth.flatMap {
            RecordingHUD.topWarning(
                from: $0.warnings, writeFailureCause: $0.writeFailureCause, unsavedTrack: $0.unsavedTrack
            )
        }
            .map { atRisk ? "⚠︎ \($0)" : $0 }
        return MenuBarRecordingPresentation(
            isAtRisk: atRisk,
            statusTitle: statusTitle,
            healthLine: healthLine,
            startTitle: "Start Recording",
            // `hasActiveTranscription` still titles the menu "Transcribing…"; it no longer greys
            // Start, which is the status line saying what is happening, not a refusal.
            startEnabled: canStartRecording,
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
///
/// "Problem" is the sentence said, not the warning case (F960). One warning, `.captureWritesFailing`,
/// is worded from the snapshot — the disk advice or not (F888), one named track or "stop" (F932) —
/// and the notification is the only surface a user behind another app has, so when that advice
/// changes it is said once more: "the rest is still recording" must not stand after the other track
/// fails too, nor "stop the recording" after system audio arrives and the microphone alone is lost.
/// Each sentence is still said once in a recording, so advice that flaps between two states is
/// bounded to one notification of each, and a change that keeps the sentence says nothing.
public struct RecordingRiskAnnouncer: Sendable {
    /// The lines already said, as `RecordingHUD.message` words them.
    private var announced: Set<String> = []

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
        let fresh = snapshot.warnings.filter(\.isAtRisk).map { warning in
            (warning: warning, line: RecordingHUD.message(
                warning, writeFailureCause: snapshot.writeFailureCause, unsavedTrack: snapshot.unsavedTrack
            ))
        }.filter { !announced.contains($0.line) }
        // The same selector as every live surface (F984), so with nothing being saved the
        // notification says "not being saved — stop" first too, rather than one tick later.
        guard let lead = RecordingHUD.leadingWarning(in: fresh.map(\.warning)),
              let worst = fresh.first(where: { $0.warning == lead }) else {
            return nil
        }
        // Only the one announced is marked, so a second problem hidden behind it still gets its turn.
        announced.insert(worst.line)
        return "Recording needs attention: \(worst.line)."
    }
}
