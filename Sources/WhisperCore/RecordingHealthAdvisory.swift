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
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
