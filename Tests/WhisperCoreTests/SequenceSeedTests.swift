import Foundation
import Testing
@testable import WhisperCore

// F604 — a new generation is numbered above every generation already on disk.
//
// The next save's number used to come from the ledger alone: `(parent ?? ledger.current).sequence
// + 1`, or 1 with no ledger. Every path that loses or rewinds the ledger — a backup restore that
// sets it aside (F463), restoring an older backup whose ledger is behind, RECOVERY.md's manual exit
// ("delete meetings.ledger.json"), a ledger commit that lagged — therefore numbered the next saves
// BELOW the history already on disk. History is ordered by that number, and retention's rule 1
// keeps "the newest three" by it, so the old generations kept the newest slots, the new saves were
// the ones pruned, and Recover Library listed the old copies first.

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
        .appendingPathComponent("SequenceSeed-\(UUID().uuidString)", isDirectory: true)
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
        writer: "aaaa0604",
        recordCount: { $0.count }
    )
}

@Test("With the ledger gone, the next saves are numbered above the history and listed first (F604)")
func savesAfterALostLedgerAreNumberedAboveTheHistory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    let now = 1_757_000_000
    var token = try store.save([Note(title: "before 1")], now: now).token
    for index in 2...6 {
        token = try store.save([Note(title: "before \(index)")], expecting: token, now: now).token
    }
    #expect(token.sequence == 6)

    // RECOVERY.md's manual exit, and what a ledger-less backup restore leaves behind (F463).
    try FileManager.default.removeItem(at: fixture.ledgerURL)

    var after: [SaveOutcomeSummary] = []
    var expecting = try #require(try store.load()).token
    for index in 1...3 {
        let outcome = try store.save([Note(title: "after \(index)")], expecting: expecting, now: now)
        after.append(SaveOutcomeSummary(sequence: outcome.token.sequence, name: outcome.retainedName))
        expecting = outcome.token
    }

    let sequences: [UInt64] = after.map(\.sequence)
    #expect(sequences == [7, 8, 9], "post-loss saves were numbered \(sequences)")
    let listed = try store.retainedGenerations()
    let newestThree = listed.prefix(3).map(\.name)
    let afterNames = after.compactMap(\.name).reversed()
    #expect(Array(newestThree) == Array(afterNames), "listed first: \(listed.map(\.name))")
}

private struct SaveOutcomeSummary {
    let sequence: UInt64
    let name: String?
}

@Test("A ledger at the top of the sequence range does not crash the next save (F604)")
func aSaturatedLedgerSequenceDoesNotTrap() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    _ = try store.save([Note(title: "one")])

    // An advisory sidecar a hand edit or a stray tool left at UInt64.max. `+ 1` traps in Swift, so
    // before this every save — every keystroke's debounced write — would have crashed the app.
    var ledger = try #require(StoreLedger.read(at: fixture.ledgerURL))
    ledger.current.sequence = .max
    #expect(try StoreLedger.write(ledger, to: fixture.ledgerURL) == .written)

    let outcome = try store.save([Note(title: "two")])
    #expect(outcome.token.sequence == .max)
    #expect(try store.load()?.value == [Note(title: "two")])
}

@Test("A history file numbered at the top of the range does not crash the next save (F604)")
func aSaturatedHistoryNameDoesNotTrap() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    _ = try store.save([Note(title: "one")])

    // A name `StoreHistory.parse` accepts — twenty digits fit a UInt64 — so the new seed reads it.
    let bytes = Data(#"[{"title":"stranger"}]"#.utf8)
    let name = "g-\(UInt64.max)-\(StoreFingerprint.of(bytes)).json"
    try bytes.write(to: fixture.historyURL.appendingPathComponent(name))

    let outcome = try store.save([Note(title: "two")])
    #expect(outcome.token.sequence == .max)
    #expect(try store.load()?.value == [Note(title: "two")])
}
