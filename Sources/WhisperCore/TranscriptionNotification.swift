import Foundation

/// How a meeting transcription finished, for the local completion notification.
public enum TranscriptionOutcome: Sendable, Equatable {
    case completed
    case failed
    case cancelled
}

/// Pure content + gating for the local "transcript ready / failed" notification (F57). Local OS
/// notification only — the body carries only the meeting title + outcome, never transcript text.
public enum TranscriptionNotification {
    /// The (title, body) to show for a finished transcription, or `nil` when nothing should be shown
    /// (cancellation). `segmentCount` is part of the stable signature for future phrasing; the
    /// completed body is deliberately the meeting title only, never transcript content.
    public static func content(
        title: String,
        outcome: TranscriptionOutcome,
        segmentCount: Int
    ) -> (title: String, body: String)? {
        switch outcome {
        case .completed:
            return ("Transcript ready", title)
        case .failed:
            return ("Transcription failed", "\(title) could not be transcribed.")
        case .cancelled:
            return nil
        }
    }

    /// Whether to actually post: never for a cancellation, and never while the app is frontmost (the
    /// user can already see the result in-window).
    public static func shouldNotify(outcome: TranscriptionOutcome, appIsActive: Bool) -> Bool {
        guard outcome != .cancelled else { return false }
        return !appIsActive
    }
}
