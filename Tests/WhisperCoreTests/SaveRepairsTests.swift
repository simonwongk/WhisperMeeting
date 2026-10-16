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

// F679 — a save whose byte budget trims an age anchor says so.
//
// After F527/F650 the budget trims only past its ceiling, and only age anchors; when it does, the user
// loses an hour, day or week undo point. Nothing reported it: `prune` returned the names it removed,
// mixed with the ones no rule kept, and `save` turned them into `prunedNames` alone.
@Test("A save whose byte budget trims an age anchor reports that generation (F679)")
func aBudgetTrimOfAnAnchorIsReported() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A one-byte budget at its ceiling: whatever the rules keep is over it, so the budget trims every
    // anchor it may, and never the newest generation or the live pair.
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0679",
        retention: RetentionPolicy(
            recentCount: 1, ageAnchors: [3_600], pinHighWaterRecordCount: false,
            byteBudget: 1, byteBudgetCeiling: 1
        ),
        recordCount: { $0.count }
    )
    let start = 1_757_000_000
    let anchor = try store.save([Note(title: "an hour and a half ago")], now: start)
    let middle = try store.save([Note(title: "a minute ago")], expecting: anchor.token, now: start + 5_000)
    let latest = try store.save([Note(title: "now")], expecting: middle.token, now: start + 5_100)

    let anchorName = try #require(anchor.retainedName)
    #expect(latest.prunedNames.contains(anchorName), "fixture: the budget did not trim the hour anchor: \(latest.prunedNames)")
    #expect(
        latest.repairs.contains(.historyTrimmedByBudget(names: [anchorName])),
        "the budget trimmed an age anchor and the save did not say so: \(latest.repairs)"
    )
}

@Test("A save whose prune removes only what no rule keeps reports no budget trim (F679)")
func anOrdinaryPruneIsNotReportedAsABudgetTrim() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0679",
        retention: RetentionPolicy(recentCount: 1, ageAnchors: [], pinHighWaterRecordCount: false),
        recordCount: { $0.count }
    )
    var token = try store.save([Note(title: "one")], now: 1_757_000_000).token
    token = try store.save([Note(title: "two")], expecting: token, now: 1_757_000_001).token
    let third = try store.save([Note(title: "three")], expecting: token, now: 1_757_000_002)

    #expect(!third.prunedNames.isEmpty, "fixture: nothing was pruned")
    #expect(!third.repairs.contains { if case .historyTrimmedByBudget = $0 { return true } else { return false } },
            "\(third.repairs)")
}
