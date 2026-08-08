import Foundation

/// Live progress of a `yt-dlp` download, derived from its `--newline` output. `fractionCompleted` and
/// `estimatedSecondsRemaining` are `nil` until yt-dlp starts reporting a `[download]` line (F183).
public struct MediaDownloadProgress: Sendable, Equatable {
    public var fractionCompleted: Double?
    public var estimatedSecondsRemaining: TimeInterval?

    public init(fractionCompleted: Double? = nil, estimatedSecondsRemaining: TimeInterval? = nil) {
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
        self.estimatedSecondsRemaining = estimatedSecondsRemaining.map { max(0, $0) }
    }
}

/// Parses yt-dlp's `--newline` progress lines into `MediaDownloadProgress`. Pure and table-tested
/// against real output, mirroring `WhisperProgressParser`'s approach. Example line:
/// `[download]  42.3% of 12.34MiB at 1.23MiB/s ETA 00:07`
public struct MediaDownloadProgressParser {
    public init() {}

    private var lastReported: MediaDownloadProgress?

    /// Feeds a chunk of raw yt-dlp output and returns the newest download progress in it, or `nil`.
    public mutating func consume(_ chunk: String) -> MediaDownloadProgress? {
        guard !chunk.isEmpty else { return nil }
        var latest: MediaDownloadProgress?
        for line in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init) {
            if let parsed = Self.parseLine(line) { latest = parsed }
        }
        guard let latest, latest != lastReported else { return nil }
        lastReported = latest
        return latest
    }

    static func parseLine(_ line: String) -> MediaDownloadProgress? {
        guard line.contains("[download]"),
              let percent = firstCapture(percentPattern, in: line, group: 1),
              let percentValue = Double(percent) else {
            return nil
        }
        let eta = firstCapture(etaPattern, in: line, group: 1).flatMap(seconds(fromClock:))
        return MediaDownloadProgress(
            fractionCompleted: percentValue / 100,
            estimatedSecondsRemaining: eta
        )
    }

    // `  42.3% of` — the download percentage.
    private static let percentPattern = #"(\d{1,3}(?:\.\d+)?)%\s+of"#
    // `ETA 00:07` — remaining time (MM:SS or HH:MM:SS); `ETA Unknown` yields no match.
    private static let etaPattern = #"ETA\s+(\d+:\d{2}(?::\d{2})?)"#

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
