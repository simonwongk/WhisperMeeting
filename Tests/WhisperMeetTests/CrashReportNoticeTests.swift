import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F370 — the app can crash and nobody finds out.
//
// macOS wrote two `WhisperMeet-*.ips` files for F356 before anybody knew there was a bug. Nothing
// at launch looked at `~/Library/Logs/DiagnosticReports`, the diagnostics export carried no crash
// information, and the whole diagnosis came from the user pasting a report by hand. F356 ran in
// the field for months.
//
// Every test here points at a fixture directory. Reading the real one would mean reading real
// crash data about real applications, which is the F70 rule applied to somebody else's files.

private func makeReportDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticReports-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@discardableResult
private func writeReport(_ name: String, at date: Date, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("{\"asi\":\"abort() called\"}".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

@Test("The reader selects reports newer than a date and ignores older ones (F370)")
func theReaderSelectsOnlyNewerReports() throws {
    let directory = try makeReportDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cutoff = Date(timeIntervalSince1970: 1_000_000)
    try writeReport("WhisperMeet-2026-09-20-120000.ips", at: cutoff.addingTimeInterval(-3_600), in: directory)
    try writeReport("WhisperMeet-2026-09-21-120000.ips", at: cutoff.addingTimeInterval(60), in: directory)
    try writeReport("WhisperMeet-2026-09-21-130000.ips", at: cutoff.addingTimeInterval(120), in: directory)

    let found = CrashReportInventory.reports(in: directory, newerThan: cutoff)
    #expect(found.map(\.fileName) == [
        "WhisperMeet-2026-09-21-130000.ips",
        "WhisperMeet-2026-09-21-120000.ips",
    ], "newest first, and the pre-cutoff one is not reported again")

    // `nil` means everything. That is what the DIAGNOSTICS EXPORT asks for — a user exporting
    // diagnostics is answering "what went wrong", and the crash from two launches ago is part of
    // the answer. The launch notice deliberately does not use it; see
    // `AppModel.reportCrashesSinceLastLaunch`, where a first launch stamps and stays quiet.
    #expect(CrashReportInventory.reports(in: directory, newerThan: nil).count == 3)
}

@Test("A report exactly at the cutoff is not reported twice (F370)")
func aReportAtTheCutoffIsNotRepeated() throws {
    let directory = try makeReportDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = Date(timeIntervalSince1970: 1_000_000)
    try writeReport("WhisperMeet-2026-09-21-120000.ips", at: stamp, in: directory)
    // Strictly-after, deliberately. Telling somebody twice about one crash is how a notice gets
    // ignored, and the launch stamp is recorded at roughly the moment the sweep runs.
    #expect(CrashReportInventory.reports(in: directory, newerThan: stamp).isEmpty)
}

@Test("Another process's reports are not ours (F370)")
func otherProcessesReportsAreIgnored() throws {
    let directory = try makeReportDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    try writeReport("WhisperMeet-2026-09-21-120000.ips", at: now, in: directory)
    try writeReport("WhisperMeetHelper-2026-09-21-120000.ips", at: now, in: directory)
    try writeReport("Safari-2026-09-21-120000.ips", at: now, in: directory)
    try writeReport("WhisperMeet-2026-09-21-120000.txt", at: now, in: directory)
    try writeReport("WhisperMeet-2026-09-21-140000.hang", at: now, in: directory)

    let found = CrashReportInventory.reports(in: directory, newerThan: nil).map(\.fileName)
    #expect(Set(found) == ["WhisperMeet-2026-09-21-120000.ips", "WhisperMeet-2026-09-21-140000.hang"],
            "\(found)")
}

@Test("A missing or unreadable directory is empty, never a throw (F370)")
func aMissingDirectoryIsNotAFailure() {
    // The normal case on a Mac that has never crashed — and this runs on the launch path that
    // recovers interrupted recordings, so it must not be able to stop one.
    let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    #expect(CrashReportInventory.reports(in: absent, newerThan: nil).isEmpty)
}

@Test("The notice names the count and the newest time, and is nil when there is nothing (F370)")
func theNoticeSaysWhatHappened() {
    #expect(CrashReportInventory.notice(for: []) == nil)
    let one = CrashReportInventory.notice(for: [
        CrashReportRecord(fileName: "WhisperMeet-1.ips", writtenAt: Date(timeIntervalSince1970: 1_700_000_000)),
    ])
    #expect(one?.hasPrefix("A crash report") == true, "\(one ?? "")")
    let two = CrashReportInventory.notice(for: [
        CrashReportRecord(fileName: "a.ips", writtenAt: Date(timeIntervalSince1970: 1_700_000_100)),
        CrashReportRecord(fileName: "b.ips", writtenAt: Date(timeIntervalSince1970: 1_700_000_000)),
    ])
    #expect(two?.hasPrefix("2 crash reports") == true, "\(two ?? "")")
    // No action button and no alarm: the crash already happened and there is nothing to do about
    // it. What the notice buys is that they know, and that a support question starts with a file
    // name instead of "it disappeared".
    #expect(two?.contains("recordings are untouched") == true)
    #expect(two?.contains("Export Diagnostics") == true)
}

@Test("The log-show command carries the predicate and a start time (F370)")
func theLogShowCommandIsUsable() {
    // The `.ips` alone was NOT enough for F356 — its `asi` said only `abort() called`. The reason
    // lived in the unified log, and this is the command nobody would think to run.
    let command = CrashReportInventory.logShowCommand(since: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(command.contains("log show"))
    #expect(command.contains("process == \"WhisperMeet\""))
    #expect(command.contains("--start"))
}

@Test("The diagnostics bundle carries the crash inventory and still no paths (F370)")
func theBundleCarriesCrashesWithoutPaths() throws {
    let input = DiagnosticsInput(
        meetings: [],
        vocabulary: [],
        crashReports: [
            CrashReportRecord(fileName: "WhisperMeet-2026-09-21-130000.ips",
                              writtenAt: Date(timeIntervalSince1970: 1_700_000_100)),
            CrashReportRecord(fileName: "WhisperMeet-2026-09-21-120000.ips",
                              writtenAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
    )
    let json = DiagnosticsBundleBuilder.json(input)
    #expect(json.contains("\"crashReportCount\" : 2"))
    #expect(json.contains("WhisperMeet-2026-09-21-130000.ips"))
    #expect(json.contains("log show"))
    // F70's guarantee is unchanged: names and epochs, never the report's contents, which are full
    // of absolute paths and loaded-image addresses.
    #expect(!json.contains("/Users/"))
    #expect(!json.contains("Library/Logs"))

    // And an app that has never crashed says so without a crash section full of nulls.
    let quiet = DiagnosticsBundleBuilder.json(DiagnosticsInput(meetings: [], vocabulary: []))
    #expect(quiet.contains("\"crashReportCount\" : 0"))
    #expect(!quiet.contains("log show"))
}

@MainActor
@Test("A crash since the last launch is announced once, and the stamp always advances (F370)")
func theLaunchNoticeFiresOnceAndStamps() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashNotice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F370.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    let reports = [CrashReportRecord(fileName: "WhisperMeet-1.ips", writtenAt: Date())]
    let asked = Locked<[Date]>([])
    model.crashReportsSince = { since in
        asked.withLock { $0.append(since) }
        return reports
    }

    // First launch: stamped, and silent. There is no "since" to sweep from, so the only honest
    // sweep would be the whole directory — every crash still on disk, from builds that predate
    // this feature, announced as though it had just happened.
    model.reportCrashesSinceLastLaunch()
    #expect(model.alertMessage == nil, "\(model.alertMessage ?? "")")
    #expect(asked.withLock { $0.isEmpty }, "a first launch must not sweep at all")
    let stamp = try #require(defaults.object(forKey: AppModel.lastLaunchKey) as? Double)

    // Second launch: the recorded stamp is what gets asked, and a report since then is announced.
    model.reportCrashesSinceLastLaunch()
    #expect(model.alertMessage?.contains("crash report") == true, "\(model.alertMessage ?? "")")
    let asked_since = try #require(asked.withLock { $0.first })
    #expect(abs(asked_since.timeIntervalSince1970 - stamp) < 0.001,
            "the recorded stamp is what gets asked next time")

    // Third launch, nothing new: nothing said.
    model.alertMessage = nil
    model.crashReportsSince = { _ in [] }
    model.reportCrashesSinceLastLaunch()
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("The stamp advances even when the sweep finds nothing or fails (F370)")
func theStampAdvancesUnconditionally() throws {
    // A stamp written only when something was found would re-report the same crash on every
    // launch until one sweep succeeded — the failure mode of every "remember what we told them"
    // feature written the obvious way round.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashStamp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F370.stamp.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    model.crashReportsSince = { _ in [] }
    #expect(defaults.object(forKey: AppModel.lastLaunchKey) == nil)
    model.reportCrashesSinceLastLaunch()
    let first = try #require(defaults.object(forKey: AppModel.lastLaunchKey) as? Double)
    #expect(model.alertMessage == nil)
    // And again, with a stamp present and a sweep that finds nothing: the stamp still advances.
    model.reportCrashesSinceLastLaunch(now: Date(timeIntervalSince1970: first + 60))
    #expect((defaults.object(forKey: AppModel.lastLaunchKey) as? Double) == first + 60)
    #expect(model.alertMessage == nil)
}

/// A `@Sendable` box for the injected sweep, which is `@Sendable` and read on the main actor.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
