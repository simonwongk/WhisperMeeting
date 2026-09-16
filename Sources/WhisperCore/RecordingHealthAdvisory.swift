import Foundation

/// A one-line, channel-level advisory for a completed recording's health rollup — shown on the meeting
/// detail so a user learns after the fact that (e.g.) no system audio was captured. Returns nil when
/// the recording was healthy. Channel-level only (microphone / system audio), never speaker identity
/// (F79, delivers F58).
public enum RecordingHealthAdvisory {
    public static func message(for report: RecordingHealthReport) -> String? {
        guard report.worstStatus != .good else { return nil }
        var notes: [String] = []
        if report.warnings.contains(.systemAudioNotDetected) || !report.systemAudioEverDetected {
            notes.append("No system (meeting) audio was detected during this recording.")
        }
        if report.warnings.contains(.systemAudioCaptureStopped) {
            notes.append("System audio capture stopped partway through.")
        }
        if report.warnings.contains(.microphoneCaptureStopped) {
            notes.append("Microphone capture stopped partway through.")
        }
        if report.warnings.contains(.microphoneClipping) {
            notes.append("The microphone was clipping (too loud) at times.")
        }
        if report.warnings.contains(.systemAudioClipping) {
            notes.append("System audio was clipping (too loud) at times.")
        }
        if report.warnings.contains(.lowStorage) {
            notes.append("Storage ran low while recording.")
        }
        // A flagged report with nothing to say about it (F188). Every note above reads `warnings`,
        // so a report written by a NEWER build — whose status or whose only warning this build does
        // not recognise — used to fall out of here as `nil` and render no advisory at all: the user
        // was shown a clean recording precisely because it had been flagged. `worstStatus` is a gate
        // here and never text, so it cannot carry the severity on its own; this is the only place the
        // fact can surface. Reachable since the lenient decode landed, which maps an unknown status
        // to `.caution` and drops unknown warnings.
        guard !notes.isEmpty else {
            return """
                This recording was flagged, but by a newer version of WhisperMeet — this version \
                cannot describe why. The recording itself is untouched.
                """
        }
        return notes.joined(separator: " ")
    }
}
