import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F476 — two ways a windowless-or-not notice went missing.
//
// Part 1: `performStartupRecovery` used to call `reportCrashesSinceLastLaunch()`, which reported
// the crash notice directly through `report(_:)` — a single `alertMessage` slot. Whenever the SAME
// launch also had something else worth saying (a recovered recording, a read-only library, an
// integrity finding), the function's own closing `report(messages.joined(...))` silently replaced
// the crash notice with nothing left of it. That is exactly the launch F370 exists for: a crash
// mid-meeting (F356's shape), then a relaunch whose orphan sweep also rebuilds something.
//
// Part 2: `AppModel.observeStorageErrors()` piped `store.$storageErrorMessage` through
// `.compactMap { $0 }.removeDuplicates()`. Dropping the nils FIRST collapses the sequence
// A, nil, A (a failure, a clearing success or dismissal, then the SAME failure again) into A, A —
// two adjacent equal elements once the nil is gone — so `removeDuplicates()` swallowed the second
// one. A repeat of an already-cleared failure never reached a user with no window open, for the
// rest of the process.

@MainActor
private func makeDegradedStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F476-Degraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    return (MeetingStore(rootDirectory: root), root)
}

@MainActor
@Test("A crash notice survives the startup summary instead of being overwritten by it (F476)")
func crashNoticeSurvivesTheStartupSummary() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F476.crash.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    // Seed a "previous launch" stamp so the crash sweep actually asks — a first launch stays silent
    // by design (`reportCrashesSinceLastLaunch`'s own doc comment). Then hand it a fixture crash
    // report through the injected seam (F370): never the user's own
    // `~/Library/Logs/DiagnosticReports`.
    defaults.set(Date().addingTimeInterval(-3_600).timeIntervalSince1970, forKey: AppModel.lastLaunchKey)
    model.crashReportsSince = { _ in
        [CrashReportRecord(fileName: "WhisperMeet-1.ips", writtenAt: Date())]
    }

    // The degraded library is the simplest way to guarantee `performStartupRecovery` has something
    // ELSE to say in the same summary — exactly the condition under which the crash notice used to
    // vanish entirely.
    await model.performStartupRecovery()

    let alert = try #require(model.alertMessage)
    #expect(alert.contains("crash report"), "the crash notice must reach the summary: \(alert)")
    #expect(alert.contains("read-only"), "the degraded-library message must also be there: \(alert)")
    let crashRange = try #require(alert.range(of: "crash report"))
    let degradedRange = try #require(alert.range(of: "read-only"))
    #expect(crashRange.lowerBound < degradedRange.lowerBound, "the crash notice must come first")
}

@MainActor
@Test("A repeated storage failure reaches the windowless channel twice, not once, after a clear (F476)")
func repeatedStorageFailureReachesTheWindowlessChannelTwice() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F476-Storage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F476.storage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = MeetingStore(rootDirectory: root)
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    model.observeStorageErrors()

    struct RemovalError: Error {}
    store.removeRecordingDirectory = { _ in throw RemovalError() }

    // A meeting with its own recording folder: deleting it while `removeRecordingDirectory` throws
    // sets `storageErrorMessage` to the SAME text every time, driven only by the title and the kept
    // count — both held constant below.
    func makeFailingMeeting() throws -> UUID {
        let id = UUID()
        let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("meeting.wav"))
        store.upsert(MeetingRecord(
            id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed
        ))
        return id
    }

    let first = try makeFailingMeeting()
    store.delete(id: first)   // fails to remove the folder -> storageErrorMessage = A
    let firstFailureMessage = try #require(store.storageErrorMessage)
    #expect(model.windowlessAlertCount == 1)
    #expect(model.lastWindowlessMessage == firstFailureMessage)

    // A real clear in between — a successful save, exactly as a freed-up disk or a dismissal would
    // produce — so `storageErrorMessage` genuinely returns to nil before the SAME failure recurs.
    store.upsert(MeetingRecord(id: UUID(), title: "other", recordingPath: "none", status: .completed))
    #expect(store.storageErrorMessage == nil)

    let second = try makeFailingMeeting()
    store.delete(id: second)   // the identical text: same title "M", same kept-count of 1
    let secondFailureMessage = try #require(store.storageErrorMessage)
    #expect(secondFailureMessage == firstFailureMessage, "the repro depends on the messages matching")
    #expect(model.windowlessAlertCount == 2, "the repeat, after a real clear, must reach the channel again")
}
