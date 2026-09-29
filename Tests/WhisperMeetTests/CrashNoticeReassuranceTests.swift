import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F640 — the crash notice ends "Nothing was lost and your recordings are untouched." whatever else
// the launch found. F476 made the notice survive into the one combined startup summary — before it,
// the notice was dropped whenever anything else had to be said, which is what hid this — so a crash
// followed by an interrupted folder that could not be rebuilt now produced one alert saying
// "Nothing was lost" beside "…could not be rebuilt and was left untouched."
//
// Driven through `performStartupRecovery()`, the launch path itself, with a fixture crash report
// through the F370 seam (never the user's own DiagnosticReports).

private struct RebuildFailed: Error, LocalizedError {
    var errorDescription: String? { "The tracks could not be read." }
}

private let reassurance = "Nothing was lost and your recordings are untouched."

@MainActor
private func makeModel(_ label: String, orphanFolders: Int = 0, degraded: Bool = false) throws -> (AppModel, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F640-\(label)-\(UUID().uuidString)")
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    for _ in 0..<orphanFolders {
        try FileManager.default.createDirectory(at: recordings.appendingPathComponent(UUID().uuidString),
                                                withIntermediateDirectories: true)
    }
    if degraded {
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    }
    let suite = "F640.\(label).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    // A previous launch, so the crash sweep asks (a first launch is silent by design, F370), and one
    // crash since it.
    defaults.set(Date().addingTimeInterval(-3_600).timeIntervalSince1970, forKey: AppModel.lastLaunchKey)
    model.crashReportsSince = { _ in [CrashReportRecord(fileName: "WhisperMeet-1.ips", writtenAt: Date())] }
    return (model, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
@Test("A crash followed by a folder that could not be rebuilt does not also say nothing was lost (F640)")
func aCrashBesideAFailedRebuildDoesNotReassure() async throws {
    let (model, cleanup) = try makeModel("failed-rebuild", orphanFolders: 1)
    defer { cleanup() }
    model.recoverInterruptedRecording = { _ in throw RebuildFailed() }

    await model.performStartupRecovery()

    let alert = try #require(model.alertMessage)
    #expect(alert.contains("crash report"), "the crash is still reported: \(alert)")
    #expect(alert.contains("could not be rebuilt"), "sanity: the loss is in the same alert: \(alert)")
    #expect(!alert.contains(reassurance), "a reassurance beside its own contradiction: \(alert)")
    #expect(alert.contains("Export Diagnostics"), "only the claim goes; the pointer to the details stays")
}

@MainActor
@Test("A crash on a launch that reads the library as damaged does not say nothing was lost either (F640)")
func aCrashBesideADamagedLibraryDoesNotReassure() async throws {
    let (model, cleanup) = try makeModel("degraded", degraded: true)
    defer { cleanup() }

    await model.performStartupRecovery()

    let alert = try #require(model.alertMessage)
    #expect(alert.contains("crash report"))
    #expect(alert.contains("read-only"))
    #expect(!alert.contains(reassurance), "\(alert)")
    let crash = try #require(alert.range(of: "crash report"))
    let readOnly = try #require(alert.range(of: "read-only"))
    #expect(crash.lowerBound < readOnly.lowerBound, "F476's order is kept: the crash notice first")
}

@Test("The summary's rule: the reassurance only when the crash notice is the whole summary, and the notice first (F640)")
func startupSummaryComposition() throws {
    let crash = [CrashReportRecord(fileName: "WhisperMeet-1.ips", writtenAt: Date())]
    #expect(AppModel.startupSummary(crashes: [], messages: []) == nil, "nothing to say, nothing reported")
    #expect(AppModel.startupSummary(crashes: [], messages: ["A", "B"]) == "A\n\nB", "no crash: unchanged")
    let alone = try #require(AppModel.startupSummary(crashes: crash, messages: []))
    #expect(alone.contains(reassurance))
    // Deliberately any other message, not only ones that read as a loss — see
    // `CrashReportInventory.notice(for:isTheWholeSummary:)` for why no phrase list decides it.
    let recovered = try #require(AppModel.startupSummary(
        crashes: crash, messages: ["Recovered Meeting Sep 28 was added back to meeting history."]
    ))
    #expect(!recovered.contains(reassurance))
    #expect(recovered.hasPrefix("A crash report"), "F476's order: the crash notice first")
    #expect(recovered.hasSuffix("was added back to meeting history."))
}

@MainActor
@Test("A crash with nothing else to report still says nothing was lost (F640)")
func aCrashAloneStillReassures() async throws {
    let (model, cleanup) = try makeModel("alone")
    defer { cleanup() }

    await model.performStartupRecovery()

    let alert = try #require(model.alertMessage)
    #expect(alert.contains("crash report"))
    #expect(alert.contains(reassurance), "the reassurance is true here, and it is the point of the notice: \(alert)")
}
