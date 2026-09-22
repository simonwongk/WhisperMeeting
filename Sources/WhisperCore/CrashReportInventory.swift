import Foundation

/// One crash report macOS wrote for this app.
///
/// The file name and its timestamp, and nothing from inside the file. An `.ips` is full of
/// absolute paths and loaded-image addresses, and `DiagnosticsBundleBuilder` promises a bundle
/// that carries neither (F70) — so this names the report rather than quoting it.
public struct CrashReportRecord: Sendable, Equatable {
    public let fileName: String
    public let writtenAt: Date

    public init(fileName: String, writtenAt: Date) {
        self.fileName = fileName
        self.writtenAt = writtenAt
    }
}

/// Finding out that the app crashed, which nothing in it could do before (F370).
///
/// macOS had already written two `WhisperMeet-*.ips` files for F356 before anybody knew there was
/// a bug. Nothing read them, the diagnostics export carried no crash information, and the entire
/// diagnosis came from the user pasting a crash report by hand.
///
/// **And the `.ips` alone was not enough**, which is the part that shapes this type. Its `asi`
/// field said only `abort() called` — no exception reason. The reason
/// ("required condition is false: format.sampleRate == hwFormat.sampleRate") lived in the unified
/// log, recoverable with `log show`, which nobody would think to run. So this surfaces *that* a
/// crash happened and hands over the exact command that recovers *why*; it does not pretend the
/// report is self-sufficient.
///
/// Read-only, no new permission, nothing uploaded — `~/Library/Logs/DiagnosticReports` is the
/// user's own directory and the app only lists it.
public enum CrashReportInventory {
    /// Where macOS writes them. Per-user, not `/Library/Logs`, which is the system-wide one.
    public static func defaultDirectory(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Reports for `processName`, newest first, written strictly after `since`.
    ///
    /// `nil` for `since` means "everything", which is what a first launch after this shipped
    /// should see — a user whose app crashed last week has not been told yet.
    ///
    /// Non-throwing and empty on any failure. A missing directory is the normal case on a Mac that
    /// has never crashed, and an unreadable one must not be able to stop a launch: this runs on
    /// the path that recovers interrupted recordings.
    public static func reports(
        in directory: URL,
        processName: String = "WhisperMeet",
        newerThan since: Date?,
        using fileManager: FileManager = .default
    ) -> [CrashReportRecord] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        // `hasPrefix(processName + "-")`, so `WhisperMeetHelper-…` is somebody else's report. The
        // extension list is both of the ones macOS uses: `.ips` since Monterey, `.crash` before it
        // and still written by some reporters.
        let prefix = processName + "-"
        var found: [CrashReportRecord] = []
        for name in names where name.hasPrefix(prefix) {
            let url = directory.appendingPathComponent(name)
            guard ["ips", "crash", "hang"].contains(url.pathExtension) else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            // Strictly after: a report whose timestamp equals the recorded launch has been
            // reported once already, and telling somebody twice about one crash is how a notice
            // gets ignored.
            if let since, modified <= since { continue }
            found.append(CrashReportRecord(fileName: name, writtenAt: modified))
        }
        return found.sorted { $0.writtenAt > $1.writtenAt }
    }

    /// The command that recovers the exception reason the report does not carry.
    ///
    /// Emitted as text for the user and for the diagnostics bundle; the app never runs it. Running
    /// `log show` on the user's behalf would read the whole system log, which is a far larger
    /// privacy surface than this feature needs and is not what F370 asked for.
    public static func logShowCommand(
        since: Date,
        processName: String = "WhisperMeet",
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "log show --predicate 'process == \"\(processName)\"' --start '\(formatter.string(from: since))'"
    }

    /// What to tell the user, or nil when there is nothing to tell them.
    ///
    /// One sentence and no action button. The crash already happened and there is nothing for them
    /// to do about it; what this buys is that they *know*, and that a support question starts with
    /// a file name instead of with "it disappeared".
    public static func notice(for reports: [CrashReportRecord]) -> String? {
        guard let newest = reports.first else { return nil }
        let when = DateFormatter.crashNotice.string(from: newest.writtenAt)
        let others = reports.count - 1
        let count = others == 0
            ? "A crash report"
            : (others == 1 ? "2 crash reports" : "\(reports.count) crash reports")
        return """
            \(count) from WhisperMeet appeared since the last launch — the most recent at \(when). \
            Nothing was lost and your recordings are untouched. \
            Export Diagnostics from Settings includes the details.
            """
    }
}

private extension DateFormatter {
    static let crashNotice: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
