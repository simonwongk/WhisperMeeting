import Foundation
import Testing
@testable import WhisperCore

// F553 — what a save worked around reaches the caller.
//
// `save()` has always built a `repairs` list — an unreadable ledger, an adopted primary, and
// `.historyUnavailable` when the retained-history step could not run — and then dropped it on the
// floor: `SaveOutcome` had no field for it. Retention is deliberately never fatal, so a save whose
// history could not be kept returns normally, and with the list thrown away nothing above
// `BackupJSONStore` could tell "saved, and the previous version kept" from "saved, and nothing kept".

private struct Note: Codable, Equatable { let title: String }

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaveRepairs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeStore(_ directory: URL) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0553",
        recordCount: { $0.count }
    )
}

@Test("A save whose history is squatted by a plain file reports it rather than dropping it (F553)")
func aSaveReportsThatItsHistoryCouldNotBeKept() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The ticket's reproduction: a plain FILE where `meetings.history/` should be.
    let squatter = directory.appendingPathComponent("meetings.history")
    try Data("not a directory".utf8).write(to: squatter)
    let store = makeStore(directory)

    let outcome = try store.save([Note(title: "kept on disk, but no past version")])

    // The save itself still succeeded — retention is never fatal, and that must not change.
    #expect(try JSONDecoder().decode(
        [Note].self, from: Data(contentsOf: directory.appendingPathComponent("meetings.json"))
    ) == [Note(title: "kept on disk, but no past version")])
    #expect(outcome.retainedName == nil)
    let unavailable = outcome.repairs.contains {
        if case .historyUnavailable = $0 { return true }
        return false
    }
    #expect(unavailable, "the save's repairs were \(outcome.repairs)")
    // And the squatter is still exactly what it was: a save that cannot keep history must not
    // "fix" the name by deleting whatever holds it.
    #expect(try Data(contentsOf: squatter) == Data("not a directory".utf8))
}

@Test("An ordinary save reports no repairs (F553)")
func anOrdinarySaveReportsNoRepairs() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(directory)

    let first = try store.save([Note(title: "one")])
    let second = try store.save([Note(title: "two")], expecting: first.token)

    #expect(first.repairs.isEmpty, "\(first.repairs)")
    #expect(second.repairs.isEmpty, "\(second.repairs)")
    #expect(second.retainedName != nil)
}

@Test("An unreadable ledger found by a save is reported by that save (F553)")
func aSaveReportsAnUnreadableLedger() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(directory)
    _ = try store.save([Note(title: "one")])
    try Data("{ torn".utf8).write(to: directory.appendingPathComponent("meetings.ledger.json"))

    let outcome = try store.save([Note(title: "two")])

    #expect(outcome.repairs.contains(.ledgerUnreadable), "\(outcome.repairs)")
}
