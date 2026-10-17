import Foundation

/// The log of a transcription helper that failed, kept beside the recording (F624).
///
/// F511 caps what reaches the alert and `meetings.json`'s `errorMessage` at a short summary of the log
/// (`SubprocessLogSummary`), because the log does not belong in either. The rest was then lost. When a
/// client is given `failureLogURL`, it writes there all of the log it kept before it throws — which is
/// the whole log up to 200 KB, and past that its last 100–200 KB (the clients' own retention). The app
/// names one file per meeting, `transcription-failure.log` in the meeting's own recording folder, and
/// removes it as each run starts, so the file is always the latest run's and a run that succeeds leaves
/// none (`AppModel.performTranscription`); the meeting's failed card offers to show it.
///
/// Best effort: a log that cannot be written leaves the failure exactly as it was without one.
public enum TranscriptionFailureLog {
    /// The file the app keeps, in a meeting's recording folder.
    public static let fileName = "transcription-failure.log"

    /// Writes `log` to `url` atomically. Nothing is written for an empty log, and an existing file is
    /// replaced. Returns whether the file was written.
    @discardableResult
    public static func write(_ log: String, to url: URL?) -> Bool {
        guard let url, !log.isEmpty else { return false }
        return (try? Data(log.utf8).write(to: url, options: .atomic)) != nil
    }
}
