import Foundation

/// Interprets the live output of the `whisper` CLI (run with `--verbose False`) into structured
/// progress. Whisper prints a `tqdm` progress bar to stderr; this parser reads those bars without
/// changing the CLI contract.
///
/// Two bars can appear, distinguished by their unit:
/// - transcription: `unit="frames"`, plain-integer `current/total`, e.g.
///   ` 62%|██████▏   | 16740/27000 [00:45<00:27, 380.12frames/s]`
/// - first-use model download: `unit="iB"` (byte-scaled), e.g.
///   ` 46%|████▌     | 1.42G/3.09G [00:12<00:14, 120MiB/s]`
///
/// `tqdm` rewrites the bar in place using carriage returns, so `consume` splits on both `\r` and
/// `\n` and reports the newest complete bar it can find.
public struct WhisperProgressParser {
    /// Text after the last line delimiter that has not yet been parsed as a complete bar.
    private var pending = ""
    /// The most recent progress reported, so an unchanged bar sitting in `pending` is not
    /// re-emitted for every subsequent chunk.
    private var lastReported: LocalTranscriptionProgress?
    private static let pendingCap = 8_192

    public init() {}

    /// Feeds a chunk of raw CLI output and returns the newest progress found in it, or `nil` if
    /// the chunk contained no recognizable progress bar.
    public mutating func consume(_ chunk: String) -> LocalTranscriptionProgress? {
        guard !chunk.isEmpty else { return nil }
        let combined = pending + chunk

        // Keep only the text after the final delimiter as the new pending remainder; everything
        // before it is settled and safe to parse.
        let settled: Substring
        if let lastDelimiter = combined.lastIndex(where: { $0 == "\r" || $0 == "\n" }) {
            settled = combined[..<lastDelimiter]
            pending = String(combined[combined.index(after: lastDelimiter)...])
        } else {
            settled = combined[...]
            pending = combined
        }
        if pending.count > Self.pendingCap {
            pending = String(pending.suffix(Self.pendingCap))
        }

        var candidates = settled.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        // The pending remainder can already hold a fully formed bar (tqdm has no trailing
        // delimiter until it finishes), so consider it too.
        candidates.append(pending)

        var latest: LocalTranscriptionProgress?
        for candidate in candidates {
            if let parsed = Self.parseBar(candidate) {
                latest = parsed
            }
        }
        guard let latest, latest != lastReported else { return nil }
        lastReported = latest
        return latest
    }

    /// Parses a single, complete tqdm bar line. Returns `nil` for anything that is not a bar.
    static func parseBar(_ line: String) -> LocalTranscriptionProgress? {
        guard let percent = firstCapture(Self.percentPattern, in: line, group: 1),
              let percentValue = Double(percent),
              line.contains("|"),
              line.contains("]") else {
            return nil
        }

        let isDownload = line.contains("iB")
        let isTranscription = line.contains("frames")

        var fraction = percentValue / 100
        // The transcription bar exposes exact integer frame counts; prefer them over the rounded
        // percentage for a smoother, more accurate bar.
        if !isDownload,
           let current = firstCapture(Self.fractionPattern, in: line, group: 1),
           let total = firstCapture(Self.fractionPattern, in: line, group: 2),
           let currentValue = Double(current),
           let totalValue = Double(total),
           totalValue > 0 {
            fraction = currentValue / totalValue
        }

        let phase: LocalTranscriptionProgress.Phase
        if isDownload {
            phase = .downloadingModel
        } else if isTranscription {
            phase = .transcribing
        } else {
            // A bar with no unit hint: integer fraction ⇒ frames (transcription); otherwise leave
            // it as transcribing, the far more common case.
            phase = .transcribing
        }

        let remaining = firstCapture(Self.remainingPattern, in: line, group: 1)
            .flatMap(Self.seconds(fromClock:))

        return LocalTranscriptionProgress(
            phase: phase,
            fractionCompleted: fraction,
            estimatedSecondsRemaining: remaining
        )
    }

    // ` 62%|` — leading percentage immediately before the bar.
    private static let percentPattern = #"(\d{1,3})%\|"#
    // `| 16740/27000 [` — plain-integer current/total (transcription only).
    private static let fractionPattern = #"\|\s*(\d+)/(\d+)\s*\["#
    // `[00:45<00:27,` — the remaining-time field of `[{elapsed}<{remaining}, {rate}]`.
    private static let remainingPattern = #"\[[^\]]*<([\d:]+)[,<]"#

    /// Converts `SS`, `MM:SS`, or `HH:MM:SS` into seconds. Returns `nil` for `?` / malformed clocks.
    static func seconds(fromClock clock: String) -> TimeInterval? {
        let parts = clock.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func firstCapture(
        _ pattern: String,
        in string: String,
        group: Int
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              group < match.numberOfRanges,
              let captureRange = Range(match.range(at: group), in: string) else {
            return nil
        }
        return String(string[captureRange])
    }
}
