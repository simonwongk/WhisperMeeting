import Foundation

/// Pure spoken-label phrasing for VoiceOver, over framework-free primitives (WhisperCore cannot see
/// the WhisperMeet types). Read-only descriptions of state — never implies identified speakers (F71).
public enum AccessibilityPhrase {
    /// e.g. "Team sync, transcript ready, 42 minutes".
    public static func meetingRow(title: String, statusRaw: String, duration: TimeInterval) -> String {
        var parts = [title, statusPhrase(statusRaw)]
        if duration > 0 { parts.append(durationPhrase(duration)) }
        return parts.joined(separator: ", ")
    }

    public static func recordButton(isRecording: Bool, isBusy: Bool) -> String {
        if isBusy { return "Recording controls unavailable" }
        return isRecording ? "Stop recording" : "Start recording"
    }

    public static func marker(label: String, offset: TimeInterval) -> String {
        "Marker \(label) at \(TranscriptFormatter.timestamp(offset))"
    }

    public static func levelMeter(channel: String, level: Float) -> String {
        "\(channel) level \(Int((max(0, min(1, level)) * 100).rounded())) percent"
    }

    static func statusPhrase(_ raw: String) -> String {
        switch raw {
        case "completed": return "transcript ready"
        case "recorded": return "ready to transcribe"
        case "processing": return "transcribing"
        case "failed": return "needs attention"
        default: return raw
        }
    }

    static func durationPhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "less than a minute" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
