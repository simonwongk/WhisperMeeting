import Foundation
import WhisperCore

/// `WhisperMeet --dictation-refine-report <path to dictation-log.json>` (F214).
///
/// `DictationRefineReport` was written so that F214's answer "costs one command rather than a
/// session", and then no command existed — a tested mechanism with no entry point, which is F289,
/// F306 and F310 again. This is the door. It lives on the app executable, as
/// `DiarizationInstallSmokeTest` does, because the report must use the app's own
/// `DictationRefinePolicy.effectiveWordCount` and the app is the only program that links it.
///
/// **Read-only, and the path is required.** It reads the one file it is given and writes nothing.
/// It takes no default path on purpose: a command that quietly found the user's dictation history
/// by itself is a different kind of command from one pointed at a file.
///
/// **What it prints is counts.** Bucket totals and rates — never dictated text, which is the most
/// private thing this app stores.
enum DictationRefineReportCommand {
    static let flag = "--dictation-refine-report"

    /// The log to report on, or nil for an ordinary app launch. Matched only in its complete
    /// flag-plus-path form, for the smoke test's reason: a bare flag must not turn a normal launch
    /// into a headless run that exits when the user expected a window.
    static func logURL(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static let sinceFlag = "--since"

    /// What `--since` asked for. Three cases and not an optional date, because "absent" and
    /// "present but not a date" must not collapse: falling back to no filter would print the
    /// blended table under a command line that asked for the filtered one — the wrong answer,
    /// looking exactly like the right one.
    enum Since: Equatable {
        case all
        case from(Date, label: String)
        case invalid(String)
    }

    /// `--since yyyy-MM-dd`, read as the start of that day in this Mac's time zone — the zone the
    /// person asking thinks in, and the one a file's modification date is shown in.
    static func since(in arguments: [String]) -> Since {
        guard let index = arguments.firstIndex(of: sinceFlag) else { return .all }
        guard index + 1 < arguments.count else { return .invalid("") }
        let raw = arguments[index + 1]
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, raw.count == 10 else { return .invalid(raw) }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        let calendar = Calendar.current
        // Round-tripped, so 2026-02-31 is rejected rather than read as early March.
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components
        else { return .invalid(raw) }
        return .from(date, label: raw)
    }

    /// The report, or a non-zero status and the reason there is none.
    ///
    /// An unreadable log must never come back as an empty table: every rate in an empty table is a
    /// dash, and a reader skims that as "no timeouts". The failure and the healthy state have to
    /// look different from outside.
    static func run(logURL: URL, since: Since = .all) -> (status: Int32, message: String) {
        let cut: (date: Date, label: String)?
        switch since {
        case .all: cut = nil
        case .from(let date, let label): cut = (date, label)
        case .invalid(let raw):
            return (2, "\(sinceFlag) needs a date as yyyy-MM-dd, not \"\(raw)\"")
        }
        let log: DictationLog
        do {
            // ISO 8601, because that is how `BackupJSONStore` writes the log.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            log = try decoder.decode(DictationLog.self, from: Data(contentsOf: logURL))
        } catch {
            return (1, "could not read a dictation log at \(logURL.path): \(error.localizedDescription)")
        }
        let report = DictationRefineReport(log: log, since: cut?.date)
        // The sample size leads. The log is capped (`DictationLog.limit`), so this is a window
        // onto recent use rather than a week's total, and a rate from a handful of dictations is
        // not a rate — the reader should meet that before the percentages.
        let counted = log.entries.filter { entry in cut.map { entry.date >= $0.date } ?? true }
        let dates = counted.map(\.date)
        var header = "\(report.totalConsidered) of \(counted.count) entries recorded a refinement outcome"
        if let first = dates.min(), let last = dates.max() {
            let format = Date.ISO8601FormatStyle().year().month().day()
            header += ", between \(first.formatted(format)) and \(last.formatted(format))"
        }
        header += ". The log keeps at most \(log.limit) entries, so older dictations have already rolled off."
        if let cut {
            let n = report.excludedAsEarlier
            header += " \(n) earlier entr\(n == 1 ? "y was" : "ies were") left out by \(sinceFlag) \(cut.label)."
        }
        return (0, header + "\n\n" + report.markdown())
    }

    static func runAndExit(logURL: URL, since: Since = .all) -> Never {
        let (status, message) = run(logURL: logURL, since: since)
        if status == 0 {
            print(message)
        } else {
            FileHandle.standardError.write(Data("dictation refine report failed: \(message)\n".utf8))
        }
        exit(status)
    }
}
