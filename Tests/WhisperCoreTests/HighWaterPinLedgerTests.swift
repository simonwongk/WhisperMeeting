import Foundation
import Testing
@testable import WhisperCore

// F517 — the high-water pin outlives the 64-record ledger window.
//
// Retention rule 3 (the high-water pin) is what keeps the 2026-08-14 wipe shape recoverable: a
// library of N meetings suffers one bad write (`[]`, or stubs), the user keeps working, and the
// generation holding N meetings must stay on disk however many saves follow. The pin can only see a
// generation's record count through the ledger — `StoreHistory.entries()` reports `recordCount: nil`
// for every file — and the ledger used to keep only the newest 64 records. So on the 65th save after
// the wipe the pinned generation's count became unknown, the pin moved to a newer generation, and
// the N-meeting generation was pruned. These tests drive the real save path, not `prune` with a
// hand-built count table, because the defect is in what the SAVE hands `prune`.

private struct Note: Codable, Equatable { let title: String }

private struct Fixture {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL
    let ledgerURL: URL
    let historyURL: URL
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HighWaterPinLedger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fixture(
        directory: directory,
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        ledgerURL: directory.appendingPathComponent("meetings.ledger.json"),
        historyURL: directory.appendingPathComponent("meetings.history", isDirectory: true)
    )
}

private func makeStore(_ fixture: Fixture) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL,
        backupURL: fixture.backupURL,
        writer: "aaaa0517",
        recordCount: { $0.count }
    )
}

@Test("The wipe shape's high-water generation survives far more than 64 later saves (F517)")
func theHighWaterPinSurvivesMoreThanSixtyFourSaves() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)

    // Every save at the SAME instant, so no age anchor can hold anything: the pin is the only rule
    // standing between the seventeen meetings and deletion, which is exactly the incident's shape
    // (ten stub saves inside one launch) stretched past the ledger's old window.
    let now = 1_757_000_000
    let seventeen = (0..<17).map { Note(title: "meeting \($0)") }
    var token = try store.save(seventeen, now: now).token
    token = try store.save([], expecting: token, now: now).token          // the bad write
    for index in 0..<100 {                                                 // the user keeps working
        token = try store.save([Note(title: "after the wipe \(index)")], expecting: token, now: now).token
    }

    let retained = try store.retainedGenerations()
    let pinned = retained.first { $0.recordCount == 17 }
    #expect(
        pinned != nil,
        "the seventeen-meeting generation was pruned; retained counts: \(retained.map { $0.recordCount.map(String.init) ?? "nil" })"
    )
    if let pinned {
        let restored = try JSONDecoder().decode([Note].self, from: try store.data(of: pinned))
        #expect(restored == seventeen)
    }
}

@Test("The ledger keeps a record for every generation still on disk, and stays bounded (F517)")
func theLedgerKeepsRecordsForRetainedGenerationsAndStaysBounded() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)

    let now = 1_757_000_000
    var token = try store.save((0..<5).map { Note(title: "real \($0)") }, now: now).token
    for index in 0..<150 {
        token = try store.save([Note(title: "later \(index)")], expecting: token, now: now).token
    }

    let ledger = try #require(StoreLedger.read(at: fixture.ledgerURL))
    let onDisk = Set(
        try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)
            .filter { $0.hasPrefix("g-") }
    )
    let recorded = Set(ledger.history.compactMap(\.historyName))
    // Every generation on disk is still described, so none of them has lost its record count.
    #expect(onDisk.isSubset(of: recorded), "on disk without a record: \(onDisk.subtracting(recorded).sorted())")
    // And the ledger did not become a log of every save ever made: the old 64-record window, plus
    // the generations still on disk, is its ceiling.
    #expect(ledger.history.count <= 64 + onDisk.count, "ledger grew to \(ledger.history.count) records")
    #expect(ledger.history.count < 151)
}
