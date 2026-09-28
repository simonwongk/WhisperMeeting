import Foundation
import Testing
@testable import WhisperCore

// F527 — the history byte budget follows the size of the index.
//
// The budget may trim only rule-2 age anchors (rules 1, 3 and 4 are exempt), and it trims whenever
// what the rules kept exceeds it. With a fixed 256 MiB and the meeting index growing ~15 MB per
// hundred meetings (F211's measurement), the three newest generations alone pass the budget at
// ~85 MB — about 570 meetings — and from then on EVERY prune dooms every hour, day and week anchor:
// Recover Library can only go back three saves. The ratio, not the absolute size, is the defect, so
// these tests reproduce it at kilobyte scale: a 30 KB floor and ~12 KB generations put the three
// newest past the floor exactly as ~85 MB generations do against 256 MiB, and exercise the real
// save path without writing hundreds of megabytes in a unit test.

private struct Note: Codable, Equatable { let title: String }

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScaledByteBudget-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// One record whose encoding is about `bytes` long, distinct per `marker` so every save is a new
/// generation with its own fingerprint. One record each, so the high-water pin sits on the newest
/// generation and cannot be what keeps an anchor alive.
private func payload(_ marker: String, bytes: Int = 12_000) -> [Note] {
    [Note(title: marker + String(repeating: "x", count: max(0, bytes - marker.count)))]
}

@Test("A large index keeps its hour, day and week anchors through an ordinary save (F527)")
func aLargeIndexKeepsItsAgeAnchors() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The shipping rules, with the floor shrunk in proportion to the payload (see the header).
    let policy = RetentionPolicy(byteBudget: 30_000)
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0527",
        retention: policy,
        recordCount: { $0.count }
    )

    let now = 1_757_000_000
    let weekOld = try store.save(payload("week"), now: now - 8 * 86_400)
    let dayOld = try store.save(payload("day"), expecting: weekOld.token, now: now - 2 * 86_400)
    let hourOld = try store.save(payload("hour"), expecting: dayOld.token, now: now - 2 * 3_600)
    var token = hourOld.token
    for index in 0..<4 {
        token = try store.save(payload("today \(index)"), expecting: token, now: now).token
    }

    let retained = Set(try store.retainedGenerations().map(\.name))
    for (label, outcome) in [("week", weekOld), ("day", dayOld), ("hour", hourOld)] {
        let name = try #require(outcome.retainedName)
        #expect(retained.contains(name), "the \(label) anchor was pruned by the byte budget")
    }
}

@Test("Past the ceiling the budget still trims the anchors, oldest first (F527)")
func pastTheCeilingTheBudgetStillTrims() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A ceiling below what the rules keep: the scaled budget stops at it, so the oldest anchor
    // goes first — the budget is still a ceiling, not a formality.
    var policy = RetentionPolicy(byteBudget: 30_000)
    policy.byteBudgetCeiling = 70_000
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0527",
        retention: policy,
        recordCount: { $0.count }
    )

    let now = 1_757_000_000
    let weekOld = try store.save(payload("week"), now: now - 8 * 86_400)
    let dayOld = try store.save(payload("day"), expecting: weekOld.token, now: now - 2 * 86_400)
    let hourOld = try store.save(payload("hour"), expecting: dayOld.token, now: now - 2 * 3_600)
    var token = hourOld.token
    for index in 0..<4 {
        token = try store.save(payload("today \(index)"), expecting: token, now: now).token
    }

    let retained = Set(try store.retainedGenerations().map(\.name))
    #expect(!retained.contains(try #require(weekOld.retainedName)), "the ceiling trimmed nothing")
    #expect(retained.contains(try #require(hourOld.retainedName)), "the ceiling trimmed newest-first")
}

@Test("The scaled budget never falls below its floor, stops at its ceiling, and cannot overflow (F527)")
func theScaledBudgetIsBoundedAndSaturates() {
    let policy = RetentionPolicy()
    // The shipping floor is untouched for an ordinary index.
    #expect(policy.effectiveByteBudget(forIndexBytes: 0) == 256 * 1024 * 1024)
    #expect(policy.effectiveByteBudget(forIndexBytes: 2_600_000) == 256 * 1024 * 1024)
    // Scaled by the number of generations the rules can keep at once — here 3 + 3 + 1 + 2 — so a
    // 100 MB index (past the old ~85 MB cliff) gets room for all of them.
    #expect(policy.maximumKeptGenerations == 9)
    #expect(policy.effectiveByteBudget(forIndexBytes: 100_000_000) == 900_000_000)
    // Stops at the ceiling, and a pathological size saturates rather than trapping.
    #expect(policy.effectiveByteBudget(forIndexBytes: 1_000_000_000) == policy.byteBudgetCeiling)
    #expect(policy.effectiveByteBudget(forIndexBytes: Int.max) == policy.byteBudgetCeiling)
    #expect(policy.effectiveByteBudget(forIndexBytes: -1) == policy.byteBudget)
    // A configured floor above the ceiling is still honoured: the ceiling caps the SCALING only.
    var generous = RetentionPolicy(byteBudget: 8 * 1024 * 1024 * 1024)
    generous.byteBudgetCeiling = 1024
    #expect(generous.effectiveByteBudget(forIndexBytes: Int.max) == 8 * 1024 * 1024 * 1024)
}
