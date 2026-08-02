import Foundation

/// Interprets the Qwen helper's live stderr (run with `verbose=True`) into determinate transcription
/// progress. mlx-audio prints a `tqdm` "Processing chunks" bar — one step per audio chunk — which this
/// parser reads without changing the helper's output contract (F101). The bar looks like:
///
///   `Processing chunks:  67%|██████▋   | 2/3 [00:00<00:00,  2.87it/s]`
///
/// `tqdm` rewrites the bar in place using carriage returns, so `consume` splits on both `\r` and `\n`
/// and reports the newest complete frame. The per-chunk `n/total` gives an exact fraction; the
/// `[elapsed<remaining, …]` field gives an ETA when tqdm knows one (`?` before the first step).
public struct QwenProgressParser {
    private var pending = ""
    private var lastReported: LocalTranscriptionProgress?
    private static let pendingCap = 8_192

    public init() {}

    public mutating func consume(_ chunk: String) -> LocalTranscriptionProgress? {
        guard !chunk.isEmpty else { return nil }
        let combined = pending + chunk

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
        candidates.append(pending) // tqdm has no trailing delimiter until it finishes.

        var latest: LocalTranscriptionProgress?
        for candidate in candidates {
            if let parsed = Self.parseChunkBar(candidate) {
                latest = parsed
            }
        }
        guard let latest, latest != lastReported else { return nil }
        lastReported = latest
        return latest
    }

    /// Parses a single "Processing chunks" frame. Returns `nil` for anything else.
    static func parseChunkBar(_ line: String) -> LocalTranscriptionProgress? {
        guard line.contains("Processing chunks"),
              let done = firstCapture(Self.fractionPattern, in: line, group: 1),
              let total = firstCapture(Self.fractionPattern, in: line, group: 2),
              let doneValue = Double(done),
              let totalValue = Double(total),
              totalValue > 0 else {
            return nil
        }
        let remaining = firstCapture(Self.remainingPattern, in: line, group: 1)
            .flatMap(Self.seconds(fromClock:))
        return LocalTranscriptionProgress(
            phase: .transcribing,
            fractionCompleted: doneValue / totalValue,
            estimatedSecondsRemaining: remaining
        )
    }

    // `| 2/3 [` — the completed/total chunk count.
    private static let fractionPattern = #"\|\s*(\d+)/(\d+)\s*\["#
    // `[00:00<00:01,` — the remaining-time field; `?` (unknown) will not match `[\d:]+`.
    private static let remainingPattern = #"\[[^\]]*<([\d:]+)[,\]]"#

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

    private static func firstCapture(_ pattern: String, in string: String, group: Int) -> String? {
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
