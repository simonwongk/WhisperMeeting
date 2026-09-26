import Foundation

/// Bounds a raw subprocess log to a short, user-facing diagnostic (F511).
///
/// `LocalWhisperClient` and `QwenASRClient` both accumulate up to ~200 KB of combined
/// stdout+stderr from their helper process. When that process exits non-zero, both already trim
/// to `String(log.suffix(4_000))` before throwing — but openai-whisper's *normal* failure mode
/// (an ffmpeg decode error or an OOM mid-file) is caught inside its own `cli()`, printed as a
/// traceback, and followed by `exit 0`. That took the *other* branch — "the process exited 0 but
/// wrote no output" — which threw the full, untrimmed log. The one useful line (a
/// `"Skipping … due to …"` message) sits at the very end, behind tens of KB of tqdm progress
/// frames, and the whole thing was re-written into `meetings.json`'s `errorMessage` on every
/// index save and shown whole in the failure alert.
///
/// Blank lines are dropped before the character budget is spent, so the fixed cap holds content
/// rather than tqdm's carriage-return padding; the count is deliberately the same 4,000 characters
/// already used for the non-zero-exit path, so both failure modes read the same way.
public enum SubprocessLogSummary {
    public static func summarize(_ log: String, maxCharacters: Int = 4_000) -> String {
        let trimmedLog = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLog.isEmpty else { return trimmedLog }

        let meaningfulLines = trimmedLog
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let condensed = meaningfulLines.joined(separator: "\n")
        // A log that is nothing but blank lines/whitespace still gets *some* answer, from the
        // original text, rather than an empty string that looks like success.
        let source = condensed.isEmpty ? trimmedLog : condensed

        guard source.count > maxCharacters else { return source }
        let tail = String(source.suffix(maxCharacters))
        return "(showing the end of a longer log)\n\(tail)"
    }
}
