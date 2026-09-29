import Foundation
import Testing
@testable import WhisperCore

// F688 — a history folder that can be written but not listed is reported, not silently filled.
//
// With `meetings.history` write-only (`chmod 0300`) every save still copies its generation in —
// retention succeeds, so `.historyUnavailable` never fired — while nothing can list the folder: no
// prune runs, the recovery list is empty, and since F648 the ledger keeps a record per save rather
// than guess which files are gone. The review's probe: 300 saves, 300 unpruned copies, 365 ledger
// records, `repairs == []` every time. The save knows — its listing failed on a folder that exists —
// so it says so, and F553's once-per-session notice carries it to the user.

private struct Note: Codable, Equatable { let title: String }

private final class ListingSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var isFailing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnlistableHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func isHistoryUnavailable(_ repair: BackupJSONStore<[Note]>.StoreRepair) -> String? {
    if case let .historyUnavailable(reason) = repair { return reason }
    return nil
}

@Test("A save that keeps its copy but cannot list the history folder reports it (F688)")
func aWrittenButUnlistedHistoryIsReported() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listing = ListingSwitch()
    var io = StoreFileIO.live
    io.contentsOfDirectory = { url, phase in
        if listing.isFailing, phase == .listHistory { throw CocoaError(.fileReadNoPermission) }
        return try StoreFileIO.live.contentsOfDirectory(url, phase)
    }
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        io: io, writer: "aaaa0688", recordCount: { $0.count }
    )
    var token = try store.save([Note(title: "one")]).token
    token = try store.save([Note(title: "two")], expecting: token).token

    listing.isFailing = true
    let outcome = try store.save([Note(title: "three")], expecting: token)

    #expect(outcome.retainedName != nil, "precondition: the copy was kept — this is not F553's case")
    let reasons = outcome.repairs.compactMap(isHistoryUnavailable)
    #expect(reasons.count == 1, "repairs were \(outcome.repairs)")
    #expect(reasons.first?.contains("meetings.history") == true, "\(reasons)")
    #expect(reasons.first?.contains("not listed") == true, "\(reasons)")
}

@Test("A write-only history folder on disk is reported by the save (F688)")
func aWriteOnlyHistoryFolderIsReported() throws {
    let directory = try makeDirectory()
    let historyURL = directory.appendingPathComponent("meetings.history", isDirectory: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyURL.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0688", recordCount: { $0.count }
    )
    var token = try store.save([Note(title: "one")]).token
    token = try store.save([Note(title: "two")], expecting: token).token

    // The ticket's reproduction, on the real filesystem.
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: historyURL.path)
    try #require(
        (try? FileManager.default.contentsOfDirectory(atPath: historyURL.path)) == nil,
        "precondition: this process cannot list a 0300 folder (it would if it ran as root)"
    )
    let outcome = try store.save([Note(title: "three")], expecting: token)

    #expect(outcome.retainedName != nil)
    #expect(outcome.repairs.contains { isHistoryUnavailable($0) != nil }, "repairs were \(outcome.repairs)")
}

@Test("A save that recreates an absent history folder reports nothing (F688)")
func anAbsentHistoryFolderIsNotReportedAsUnlistable() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0688", recordCount: { $0.count }
    )
    // A new library's first save, and a later save after the folder was deleted by hand: the
    // listing fails in both because there is no folder, and the save creates one. Nothing is wrong,
    // so nothing may be said — a notice on every new library's first save would be noise.
    let first = try store.save([Note(title: "one")])
    try FileManager.default.removeItem(at: directory.appendingPathComponent("meetings.history"))
    let recreated = try store.save([Note(title: "two")], expecting: first.token)

    #expect(first.repairs.isEmpty, "\(first.repairs)")
    #expect(recreated.repairs.isEmpty, "\(recreated.repairs)")
    #expect(recreated.retainedName != nil)
}
