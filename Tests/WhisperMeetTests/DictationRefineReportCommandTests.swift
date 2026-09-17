import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F214 — `DictationRefineReport` was written so that "the answer costs one command", and no command
// existed: `grep -rn DictationRefineReport Sources/` returned only its own file. That is F289, F306
// and F310's defect again — a correct, tested mechanism behind no door — and the last test here is
// the reachability pin F306 taught, asserted against the launcher's source because a headless run
// cannot start the executable and watch it exit.

private func writeLog(_ entries: [DictationLogEntry], named: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(named)-\(UUID().uuidString).json")
    // Encoded the way the store writes it (`BackupJSONStore`: ISO 8601 dates), so a reader that
    // assumed the default strategy fails here rather than on the user's real log.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(DictationLog(entries: entries)).write(to: url)
    return url
}

private func entry(_ words: Int, _ refinement: DictationRefinement) -> DictationLogEntry {
    DictationLogEntry(
        id: UUID(), date: Date(timeIntervalSince1970: 1_758_000_000),
        text: (0..<words).map { "word\($0)" }.joined(separator: " "),
        outcome: .pasted, refinement: refinement.rawValue
    )
}

@Test("Only the complete flag-plus-path form is a request for the report (F214)")
func reportFlagNeedsItsPath() {
    // The smoke test's rule, for its reason: a bare flag must not turn an ordinary launch into a
    // headless run that exits when the user expected a window.
    #expect(DictationRefineReportCommand.logURL(in: ["WhisperMeet"]) == nil)
    #expect(DictationRefineReportCommand.logURL(in: ["WhisperMeet", "--dictation-refine-report"]) == nil)
    #expect(
        DictationRefineReportCommand.logURL(
            in: ["WhisperMeet", "--dictation-refine-report", "/tmp/log.json"]
        )?.path == "/tmp/log.json"
    )
}

@Test("The command reads a real log file and prints the bucketed table (F214)")
func reportCommandReadsALogFile() throws {
    let url = try writeLog([
        entry(10, .refined), entry(30, .rawTimeout), entry(30, .refined), entry(50, .rawTimeout),
    ], named: "RefineReport")
    defer { try? FileManager.default.removeItem(at: url) }

    let result = DictationRefineReportCommand.run(logURL: url)
    #expect(result.status == 0)
    #expect(result.message.contains("| 21–40 | 2 | 2 | 1 | 50% |"))
    #expect(result.message.contains("| 41–60 | 1 | 1 | 1 | 100% |"))
    // The sample size leads, because a rate from four dictations is not a rate.
    #expect(result.message.contains("4 of 4 entries recorded a refinement outcome"))
}

@Test("A log that cannot be read is a failure with a reason, never an empty table (F214)")
func reportCommandFailsLoudlyOnAnUnreadableLog() throws {
    // An empty table reads as "no timeouts". A missing or undecodable file must not be able to
    // produce one — the failure and the healthy state have to look different from outside.
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-log-\(UUID().uuidString).json")
    let absent = DictationRefineReportCommand.run(logURL: missing)
    #expect(absent.status != 0)
    #expect(!absent.message.contains("| words |"))

    let corrupt = FileManager.default.temporaryDirectory
        .appendingPathComponent("corrupt-log-\(UUID().uuidString).json")
    try Data("{ \"entries\": [".utf8).write(to: corrupt)
    defer { try? FileManager.default.removeItem(at: corrupt) }
    let broken = DictationRefineReportCommand.run(logURL: corrupt)
    #expect(broken.status != 0)
    #expect(!broken.message.contains("| words |"))
}

@Test("The command does not modify the log it reads (F214)")
func reportCommandIsReadOnly() throws {
    let url = try writeLog([entry(30, .rawTimeout)], named: "RefineReportReadOnly")
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    _ = DictationRefineReportCommand.run(logURL: url)

    #expect(try Data(contentsOf: url) == before)
}

@Test("The launcher actually calls the report command (F214)")
func launcherCallsTheReportCommand() throws {
    // Asserted against `AppEntry`'s source, comments stripped — F306's method and its reason: the
    // tests above drive the command directly, which is the right way to test it and structurally
    // cannot notice that nothing calls it.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Sources/WhisperMeet/AppEntry.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")
    #expect(source.contains("DictationRefineReportCommand.logURL(in: CommandLine.arguments)"))
    #expect(source.contains("DictationRefineReportCommand.runAndExit"))
}

// MARK: - `--since`: the question is about one build, and the log spans two

@Test("Entries from before the cut are left out of the table and the sample size (F214)")
func reportCommandHonoursSince() throws {
    // The real log ran 2026-09-10…17 and F212 reached the runtime on the evening of the 11th, so a
    // blended table answers a question nobody asked. Excluded entries are COUNTED in the header:
    // a filter that silently shrinks the sample is how a flattering number gets made.
    func dated(_ day: Int, _ refinement: DictationRefinement) -> DictationLogEntry {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 9, day, 12)
        return DictationLogEntry(
            id: UUID(), date: Calendar.current.date(from: parts)!,
            text: (0..<30).map { "word\($0)" }.joined(separator: " "),
            outcome: .pasted, refinement: refinement.rawValue
        )
    }
    let url = try writeLog(
        [dated(10, .rawTimeout), dated(11, .rawTimeout), dated(12, .refined), dated(14, .rawTimeout)],
        named: "RefineReportSince"
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let since = DictationRefineReportCommand.since(in: ["x", "--since", "2026-09-12"])
    guard case .from = since else {
        Issue.record("a yyyy-MM-dd date must parse, got \(since)")
        return
    }
    let result = DictationRefineReportCommand.run(logURL: url, since: since)
    #expect(result.status == 0)
    #expect(result.message.contains("| 21–40 | 2 | 2 | 1 | 50% |"))
    #expect(result.message.contains("2 earlier entries were left out by --since 2026-09-12"))
}

@Test("A --since that is not a date is a failure, not an unfiltered report (F214)")
func reportCommandRejectsAnUnparseableSince() throws {
    // Falling back to "no filter" would print the blended table under a command line that asked
    // for the filtered one — the wrong answer, looking exactly like the right one.
    #expect(DictationRefineReportCommand.since(in: ["x"]) == .all)
    #expect(DictationRefineReportCommand.since(in: ["x", "--since", "last tuesday"]) == .invalid("last tuesday"))
    #expect(DictationRefineReportCommand.since(in: ["x", "--since"]) == .invalid(""))

    let url = try writeLog([entry(30, .rawTimeout)], named: "RefineReportBadSince")
    defer { try? FileManager.default.removeItem(at: url) }
    let result = DictationRefineReportCommand.run(logURL: url, since: .invalid("last tuesday"))
    #expect(result.status != 0)
    #expect(!result.message.contains("| words |"))
}
