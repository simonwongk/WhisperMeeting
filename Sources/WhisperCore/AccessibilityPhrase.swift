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

    /// Reads one anonymous speaker label on a transcript line. Always says "inferred" — and says it
    /// before the words, so the qualification is heard rather than tacked on at the end (F220).
    ///
    /// This is where the rule at the top of this file is easiest to break: on screen the label sits
    /// inside a legend that explains what it is and is not, but VoiceOver reads the row alone. A
    /// bare "Nadia, 02:05, we should ship it" is indistinguishable from a claim that Nadia spoke, so
    /// the qualification travels with the label itself. `label` is equally an anonymous cluster name
    /// or a label the reader typed: both are guesses about voices, so both are spoken the same way.
    public static func speakerLabel(_ label: String, offset: TimeInterval, text: String) -> String {
        "\(label), inferred, \(TranscriptFormatter.timestamp(offset)), \(text)"
    }

    public static func levelMeter(channel: String, level: Float) -> String {
        "\(channel) level \(Int(saturating: Double((max(0, min(1, level)) * 100).rounded()))) percent"
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
        let minutes = Int(saturating: seconds / 60)   // traps otherwise (F287's family)
        if minutes < 1 { return "less than a minute" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
