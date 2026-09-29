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

    /// Where the library windows stand for someone who has to be told something now (F528, F674).
    /// Only a library window counts: it is the only one with an `.alert` host and the at-risk banner.
    public enum WindowPresence: Sendable, Equatable {
        /// No library window the user could read: none open (Settings or Keyboard Shortcuts alone
        /// do not count), or every one minimised or on another Space.
        case noReadableWindow
        /// A readable library window exists, but something is in front of it — another app, or
        /// WhisperMeet's own Settings or Keyboard Shortcuts window.
        case behindOtherApps
        /// A readable library window is the key window of the active app.
        case inFront
    }

    /// One of the app's windows, as the presence decision needs it (F674).
    public struct WindowFacts: Sendable, Equatable {
        /// Whether it shows the meeting library (`ContentView`) — the only window with an `.alert`
        /// host and the at-risk banner. Settings and Keyboard Shortcuts are not.
        public let isLibraryWindow: Bool
        /// `isReadable`'s answer for it.
        public let isReadable: Bool
        public let isKey: Bool

        public init(isLibraryWindow: Bool, isReadable: Bool, isKey: Bool) {
            self.isLibraryWindow = isLibraryWindow
            self.isReadable = isReadable
            self.isKey = isKey
        }
    }

    /// F674: decided on library windows, not on "the app is active". F528 counted any readable
    /// window and called the app "in front" whenever it was active, so with only Settings or
    /// Keyboard Shortcuts open — or either in front of the library window — an at-risk warning was
    /// neither posted nor bannered, and a `report` waited on an alert no open window hosts.
    public static func presence(of windows: [WindowFacts], appIsActive: Bool) -> WindowPresence {
        let library = windows.filter { $0.isLibraryWindow && $0.isReadable }
        guard !library.isEmpty else { return .noReadableWindow }
        return appIsActive && library.contains(where: \.isKey) ? .inFront : .behindOtherApps
    }

    /// Whether a recording-risk announcement is posted as a notification (F528).
    ///
    /// Not `shouldPost`'s rule, which holds back whenever a readable window exists because that
    /// window's `.alert` shows the message. An announcement is never on the alert: in a window it is
    /// a banner. So the only question is whether the user is looking at WhisperMeet at all, and a
    /// window behind the call app they are in does not count — which is the meeting's normal shape.
    public static func shouldAnnounceRecordingRisk(presence: WindowPresence) -> Bool {
        presence != .inFront
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
