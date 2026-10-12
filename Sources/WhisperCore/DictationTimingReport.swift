import Foundation

/// The slowest dictations in the history, with the four figures F892 records (F892).
///
/// F891's question — what made a dictation slow — could only be asked of the unified log, which
/// this Mac keeps for about a day. The history now keeps the figures with each dictation, and this
/// is the table `--dictation-refine-report` prints from them, so a slow episode reported days later
/// is one command away. Like the refine table beside it, it prints figures and outcomes, never the
/// dictated text and never a failure's reason.
public struct DictationTimingReport {
    public struct Row: Sendable, Equatable {
        public let date: Date
        /// How the dictation ended, by case name — pasted, clipboard, empty, failed, or the name a
        /// newer build recorded (`outcomeKind`).
        public let result: String
        public let timings: DictationTimings
        public let refinement: String?
    }

    /// Slowest first: the recognizer's seconds plus the refiner's, the wait the user had between
    /// letting go of the key and the text arriving (or, for a failed dictation, the failure). Only
    /// entries that recorded the recognizer's time — ones from before F892, and "nothing heard"
    /// clips that never reached a model, have none.
    public private(set) var rows: [Row] = []

    /// - Parameters:
    ///   - since: count only entries dated at or after this, as `DictationRefineReport` does.
    ///   - limit: how many rows to keep.
    public init(log: DictationLog, since: Date? = nil, limit: Int = 10) {
        let measured = log.entries.compactMap { entry -> (wait: Double, row: Row)? in
            if let since, entry.date < since { return nil }
            guard let recognizer = entry.transcribeSeconds else { return nil }
            let row = Row(
                date: entry.date, result: Self.result(of: entry), timings: entry.timings,
                refinement: entry.refinement
            )
            return (recognizer + (entry.refineSeconds ?? 0), row)
        }
        // Stable for equal waits: the log is most recent first, and so is a tie here.
        let sorted = measured.enumerated()
            .sorted { $0.element.wait != $1.element.wait ? $0.element.wait > $1.element.wait : $0.offset < $1.offset }
            .map(\.element.row)
        rows = Array(sorted.prefix(max(0, limit)))
    }

    /// The table, with each date in `timeZone` — the zone the reader thinks in, and the one the
    /// command's `--since` is read in.
    public func markdown(timeZone: TimeZone = .current) -> String {
        guard !rows.isEmpty else {
            return "No dictation in this log recorded its timings (they are recorded from F892 on)."
        }
        let dateFormat = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: timeZone)
            .year().month().day().time(includingFractionalSeconds: false)
        var lines = [
            "| when | result | clip | recognizer | refiner | GPU before | refinement |",
            "|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            let timings = row.timings
            lines.append(
                "| \(row.date.formatted(dateFormat)) | \(row.result) | \(Self.seconds(timings.clipSeconds)) "
                + "| \(Self.seconds(timings.transcribeSeconds)) | \(Self.seconds(timings.refineSeconds)) "
                + "| \(timings.gpuBusyPercent.map { "\($0) %" } ?? "—") | \(row.refinement ?? "—") |"
            )
        }
        lines.append("")
        lines.append(
            "A dash is *not measured*, never a zero. **recognizer** runs from the release to the "
            + "recognizer's reply (the \"transcribed in\" log line), or to the failure for a **failed** "
            + "row; **refiner** is its own pass, a dash when it was not asked; **GPU before** is how busy "
            + "the GPU was just before recognition (F890)."
        )
        return lines.joined(separator: "\n")
    }

    private static func result(of entry: DictationLogEntry) -> String {
        if let kind = entry.outcomeKind { return kind }
        switch entry.outcome {
        case .pasted: return "pasted"
        case .clipboard: return "clipboard"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }

    /// `String(format:)` with `%.2f` reads a `Double` and never converts it to an integer, so a
    /// figure of any size prints rather than traps.
    private static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "—"
    }
}
