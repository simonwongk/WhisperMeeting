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
            topWarning: health.flatMap {
                topWarning(from: $0.warnings, writeFailureCause: $0.writeFailureCause, unsavedTrack: $0.unsavedTrack)
            },
            level: max(0, min(1, level))
        )
    }

    /// Show the passive HUD only while recording AND the app is backgrounded (in-window panels cover
    /// the foreground case).
    public static func shouldPresent(isRecording: Bool, appIsActive: Bool) -> Bool {
        isRecording && !appIsActive
    }

    /// The single most-severe warning's message, or nil when there are none.
    static func topWarning(
        from warnings: [RecordingHealthWarning],
        writeFailureCause: RecordingWriteFailureCause?,
        unsavedTrack: RecordingChannel?
    ) -> String? {
        warnings.min(by: { rank($0) < rank($1) }).map {
            message($0, writeFailureCause: writeFailureCause, unsavedTrack: unsavedTrack)
        }
    }

    /// Severity rank (lower = worse). Consistent with `RecordingHealthSnapshot.overallStatus`, which
    /// treats stopped-capture and low storage as at-risk.
    static func rank(_ warning: RecordingHealthWarning) -> Int {
        switch warning {
        // Worst, alongside a dead channel, and for the same reason: audio is being lost right
        // now. Arguably worse — a stopped channel still leaves the other one, and this leaves
        // nothing (F386).
        case .microphoneCaptureStopped, .systemAudioCaptureStopped, .captureWritesFailing: return 0
        // Ranked with low storage (F150): both mean "this recording is about to stop being fully
        // usable and only you can prevent it", and both are fixed the same way — stop and start a
        // new one. Above clipping, which degrades quality; below a dead channel, which is losing
        // audio right now.
        case .lowStorage, .approachingLengthLimit: return 1
        case .systemAudioNotDetected: return 2
        case .microphoneClipping, .systemAudioClipping: return 3
        }
    }

    /// `writeFailureCause` (F888) and `unsavedTrack` (F932) are the snapshot's, and have no default
    /// so that every surface that words a live warning has to say where they came from.
    static func message(
        _ warning: RecordingHealthWarning,
        writeFailureCause: RecordingWriteFailureCause?,
        unsavedTrack: RecordingChannel?
    ) -> String {
        switch warning {
        case .microphoneCaptureStopped: return "Microphone capture stopped"
        case .systemAudioCaptureStopped: return "System audio capture stopped"
        case .lowStorage: return "Low storage — recording may stop soon"
        // The consequence, not the cause. "Appends are failing" means nothing; "not being saved"
        // is the only part a user can act on, and the action is to stop rather than keep going,
        // except when one track alone is lost to its format and the other is still being saved
        // (F932). The disk advice only when the disk may be what failed (F888): a track whose
        // captured audio cannot be read fails the same way, and the disk is fine.
        case .captureWritesFailing:
            if let lost = onlyTrackLostToItsFormat(writeFailureCause: writeFailureCause, unsavedTrack: unsavedTrack) {
                return "\(lost) audio is not being saved — the rest is still recording"
            }
            return writeFailureCause == .format
                ? "Audio is not being saved — stop the recording"
                : "Audio is not being saved — stop and check disk space"
        // States the consequence, not the cause: "the WAV length field overflows" means nothing to
        // anyone, and the action is the same either way.
        case .approachingLengthLimit:
            return "Very long recording — stop soon so the whole file stays readable"
        case .systemAudioNotDetected: return "No system audio detected"
        case .microphoneClipping: return "Microphone is clipping"
        case .systemAudioClipping: return "System audio is clipping"
        }
    }

    /// The in-window health panel's sentence for `.captureWritesFailing` (F386). Here rather than in
    /// the panel's view because it depends on the cause (F888) and on whether one track alone is
    /// lost (F932), and a choice made here is tested; the panel's other sentences carry no logic.
    public static func failingWritesDetail(
        writeFailureCause: RecordingWriteFailureCause?,
        unsavedTrack: RecordingChannel?
    ) -> String {
        if let lost = onlyTrackLostToItsFormat(writeFailureCause: writeFailureCause, unsavedTrack: unsavedTrack) {
            return "\(lost) audio is no longer being written to disk; the rest is still recording. What was captured before now is safe."
        }
        return writeFailureCause == .format
            ? "Stop this recording: audio is no longer being written to disk. What was captured before now is safe."
            : "Stop this recording: audio is no longer being written to disk. Check free space. What was captured before now is safe."
    }

    /// The name of the one track lost when only its captured audio cannot be read and the other is
    /// still being saved, or nil (F932). The user's decision, 2026-10-12: that case names the track
    /// and drops "stop", since stopping would also end the audio still being saved; F386's "stop"
    /// stays where nothing is being saved. Only the format's failure is named: a track lost to its
    /// format is that source's alone, while a storage failure is the volume's, so the track still
    /// landing on it is the next to fail, and "the rest is still recording" would be the
    /// announcement a user behind another app keeps (each warning is announced once in a recording)
    /// while the disk fills. That restriction was chosen in F932's change, not by the user.
    private static func onlyTrackLostToItsFormat(
        writeFailureCause: RecordingWriteFailureCause?,
        unsavedTrack: RecordingChannel?
    ) -> String? {
        guard writeFailureCause == .format, let unsavedTrack else { return nil }
        switch unsavedTrack {
        case .microphone: return "Microphone"
        case .systemAudio: return "System"
        }
    }
}
