import Foundation

/// One of the optional runtimes WhisperMeet installs from Settings (F567).
public enum ModelInstallComponent: String, CaseIterable, Sendable {
    case whisper
    case qwen
    case summarizer
    case diarization
    case askEmbeddings

    /// How an installer message names the runtime. Capitalised: it starts a sentence.
    public var displayName: String {
        switch self {
        case .whisper: "Local Whisper"
        case .qwen: "Qwen3-ASR"
        case .summarizer: "The local summarization model"
        case .diarization: "Speaker analysis"
        case .askEmbeddings: "The search-by-meaning model"
        }
    }
}

/// Why an install did not leave its runtime ready (F567).
///
/// Before this, each installer wrapped its script's log tail in the error type of the feature it
/// installs, so a failed install read as a failed *use* of that feature: Whisper and Qwen as
/// "…transcription failed: <2,000 characters of log>", and speaker analysis as "Speaker analysis did
/// not finish. Your transcript is unchanged." — `LocalDiarizationError.processFailed` never renders
/// its associated value, so the one line that said what was wrong was dropped entirely.
///
/// `reason` is the script's last output line. Every installer phrases its refusals for users
/// ("Could not download the speaker-analysis files. Check your connection and try again."), and a
/// failure it did not anticipate — a pip resolution error, a Python traceback — still ends on the
/// line that names it.
public enum InstallerError: LocalizedError, Equatable, Sendable {
    /// The installer exited non-zero.
    case scriptFailed(ModelInstallComponent, reason: String, previousKept: Bool)
    /// The installer exited cleanly, but the runtime it was meant to leave is not there.
    case notReady(ModelInstallComponent)
    /// The installer never ran.
    case couldNotStart(ModelInstallComponent, reason: String)

    public var component: ModelInstallComponent {
        switch self {
        case let .scriptFailed(component, _, _), let .notReady(component), let .couldNotStart(component, _):
            component
        }
    }

    /// The same failure, now knowing whether a previous install is still in place. The runner cannot
    /// know that — only a probe after the script exits can — so it reports `false` and the caller
    /// settles it.
    public func keepingPrevious(_ kept: Bool) -> InstallerError {
        guard case let .scriptFailed(component, reason, _) = self else { return self }
        return .scriptFailed(component, reason: reason, previousKept: kept)
    }

    /// The sentence after "…could not be installed." / "Installation failed.".
    public var reason: String {
        switch self {
        case let .scriptFailed(_, reason, previousKept):
            // Most installers already end on that claim ("…the previous runtime was restored.",
            // "…the existing model was not changed."); saying it again read as "kept" twice.
            let addsClaim = previousKept && !InstallerOutput.claimsPreviousKept(reason)
            return Self.sentence(reason) + (addsClaim ? " The previous version was kept." : "")
        case .notReady:
            return "The installer finished, but the installed files could not be found. Try again."
        case let .couldNotStart(_, reason):
            return "The installer could not be started: " + Self.sentence(reason)
        }
    }

    public var errorDescription: String? {
        "\(component.displayName) could not be installed. \(reason)"
    }

    /// The line under the runtime's row in Settings, which outlives the alert.
    public var statusMessage: String {
        "Installation failed. \(reason)"
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }
}

public enum InstallerOutput {
    /// Longest reason shown. The scripts' own lines are well under this; the cap is for a line
    /// nobody wrote for a person, like a pip dependency dump.
    public static let maximumReasonLength = 300

    /// The last line of an installer's output that says anything, as it would read in a terminal.
    ///
    /// A progress bar redraws itself with `\r` on one physical line, so only what follows the last
    /// `\r` is what a terminal would show; ANSI colour codes are dropped. Nil when there is nothing.
    public static func lastLine(of output: String) -> String? {
        let lines = output
            .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { line -> String in
                let visible = line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                return visible
                    .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        guard last.count > maximumReasonLength else { return last }
        return String(last.prefix(maximumReasonLength)) + "…"
    }

    /// `lastLine`, or a sentence naming the exit status when the installer printed nothing.
    public static func failureReason(output: String, exitStatus: Int32) -> String {
        lastLine(of: output) ?? "The installer stopped with status \(exitStatus) and printed no reason."
    }

    /// The phrasings the installers use to say the previous install is still in place. A line
    /// worded some other way just gets the app's own sentence after it — a repeat, never a
    /// missing claim. `InstallerErrorTests` checks every `print -u2` line of every installer.
    static let previousKeptPhrases = ["was kept", "was restored", "was not changed", "nothing was changed"]

    /// Whether an installer's line already says the previous install is still in place.
    public static func claimsPreviousKept(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return previousKeptPhrases.contains { lowered.contains($0) }
    }
}
