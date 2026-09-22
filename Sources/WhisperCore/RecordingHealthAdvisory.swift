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
            notes.append(clippingNote(
                subject: "The microphone",
                measured: report.microphoneFramesMeasured,
                atFullScale: report.microphoneFramesAtFullScale,
                sustainedTail: " Move the microphone further away or lower its input level."
            ))
        }
        if report.warnings.contains(.systemAudioClipping) {
            notes.append(clippingNote(
                subject: "System audio",
                measured: report.systemAudioFramesMeasured,
                atFullScale: report.systemAudioFramesAtFullScale,
                // No action. Nothing here establishes that changing a source app's own volume
                // changes what the capture receives, and the live surfaces make the same
                // distinction — the microphone gets an instruction, system audio does not.
                sustainedTail: " The source may already have been at its limit before it reached this Mac."
            ))
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

    /// What to say about clipping, from the evidence rather than from the bare flag (F346).
    ///
    /// The sentence this replaces — "was clipping (too loud) at times" — was the defect, not just
    /// imprecise. It said the identical thing about a recording with 139 full-scale samples in 14.4
    /// million and one that is flat-topped for a seventh of its length, and it sent a real
    /// investigation after a capture-level fault that was actually in the mixer (F345).
    ///
    /// So the number is reported and the verdict is not. A count of N frames out of M cannot be
    /// wrong; only its interpretation can, and interpretation is the part that was wrong. The bands
    /// exist to keep the *tone* proportionate, not to decide anything the reader cannot re-derive
    /// from the figures in the same sentence.
    ///
    /// The `nil` band is every report written before F346 — and it deliberately does not keep the
    /// old wording, because the old wording is what is being removed.
    static func clippingNote(
        subject: String,
        measured: Int?,
        atFullScale: Int?,
        sustainedTail: String
    ) -> String {
        guard let measured, let atFullScale, measured > 0, atFullScale <= measured else {
            return "\(subject) came close to full scale at times. "
                + "This recording predates the measurement that would say how close, or how often."
        }
        if atFullScale == 0 {
            return "\(subject) came close to full scale, but not one of its "
                + "\(grouped(measured)) samples reached it, so nothing was clipped."
        }
        let fraction = Double(atFullScale) / Double(measured)
        if fraction < 0.0001 {
            let oneIn = Int(saturating: (1 / fraction).rounded())
            return "\(subject) reached full scale on \(grouped(atFullScale)) of "
                + "\(grouped(measured)) samples — about 1 in \(grouped(oneIn)). "
                + "That is far too few to be a level problem."
        }
        if fraction < 0.01 {
            return "\(subject) reached full scale on \(grouped(atFullScale)) of "
                + "\(grouped(measured)) samples (\(percent(fraction))) — a small share of the "
                + "recording, but enough that some of it may be distorted."
        }
        return "\(subject) was at full scale for \(grouped(atFullScale)) of "
            + "\(grouped(measured)) samples (\(percent(fraction))). The waveform is flat-topped "
            + "there and will sound distorted." + sustainedTail
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func percent(_ fraction: Double) -> String {
        fraction >= 0.01
            ? String(format: "%.0f%%", fraction * 100)
            : String(format: "%.2f%%", fraction * 100)
    }

}
