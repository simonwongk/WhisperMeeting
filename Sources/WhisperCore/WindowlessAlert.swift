import Foundation

/// What to do with a user-facing message when there is no window to show it in (F257).
///
/// Every lifecycle hook and the app's only error surface hang off a view inside the `WindowGroup`,
/// while the app deliberately stays alive with no window via `MenuBarExtra`. Recording from the menu
/// bar with the window closed — a normal state during a meeting — meant **no alert at all**:
/// "Recovered Meeting … was added back to meeting history" and "changes could not be saved" simply
/// did not appear. Those are the user-facing half of the recovery guarantees `PRODUCT_SPEC.md`
/// promises to "surface in plain language".
///
/// Pure, so the decision is testable without a window to close — the same shape as
/// `TranscriptionNotification`, which this deliberately mirrors rather than extends: that type
/// answers "did a transcription finish", this one answers "can the user see anything at all".
public enum WindowlessAlert {
    /// Notification bodies are clipped by the system, so the cut is made here to land somewhere
    /// readable. `storageErrorMessage` can carry a whole `NSError` description.
    public static let maximumBodyCharacters = 240

    /// Whether a window with these properties is one the user can actually read an alert in (F294).
    ///
    /// F257 asked only "visible and main-capable", which was never checked against the two states
    /// a meeting produces: a minimised window, and a window left on another Space while the user is
    /// in a full-screen call. AppKit reports a minimised window as not visible, but a window on
    /// another Space **is** visible by its own account — so that user got no notification and an
    /// alert they could not see. Both now count as "no window".
    public static func isReadable(
        isVisible: Bool, canBecomeMain: Bool, isMiniaturized: Bool, isOnActiveSpace: Bool
    ) -> Bool {
        isVisible && canBecomeMain && !isMiniaturized && isOnActiveSpace
    }

    /// Whether to post a notification for `message`.
    ///
    /// Only with no window: with one, the `.alert` host already renders it, and posting as well
    /// would show the same message twice — which is how people learn to dismiss this app's
    /// notifications without reading them.
    public static func shouldPost(hasVisibleWindow: Bool, message: String) -> Bool {
        guard !hasVisibleWindow else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The notification to post for `message`.
    ///
    /// The title is the app's name and carries no content — the body is the message the in-window
    /// alert would have shown. Notification text is visible on a lock screen, so nothing is
    /// summarised or re-worded here: what the user would have read is what they read.
    public static func content(for message: String) -> (title: String, body: String) {
        ("WhisperMeet", flattened(message))
    }

    /// One line, trimmed, and cut on a word boundary when too long.
    ///
    /// Newlines become spaces because `alertMessage` is assembled for an in-window alert that
    /// renders them; a notification body does not, so the raw breaks would show.
    private static func flattened(_ message: String) -> String {
        let oneLine = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard oneLine.count > maximumBodyCharacters else { return oneLine }
        let clipped = oneLine.prefix(maximumBodyCharacters)
        // Back up to the last space so the ellipsis follows a whole word. A message with no space
        // in its first 240 characters keeps the hard cut, which is the right answer for a path or
        // an identifier — breaking those is worse than clipping them.
        guard let lastSpace = clipped.lastIndex(of: " ") else { return clipped + "…" }
        return clipped[..<lastSpace] + "…"
    }
}
