import Foundation
import Testing
@testable import WhisperCore

// F650 — the history budget is sized by what retention keeps, not by the index just written.
//
// F527 scaled the byte budget with `newData.count`. A wipe or a mass delete shrinks exactly that,
// so the save that writes `[]` over a large library fell back to the 256 MiB floor and trimmed the
// hour, day and week anchors — the older, larger generations that are the way back — in the one
// save where they matter most. Same kilobyte-scale ratio as `ScaledByteBudgetTests`: a 30 KB floor
// and ~12 KB generations stand in for 256 MiB and a large index.

private struct Note: Codable, Equatable { let title: String }

private func payload(_ marker: String, bytes: Int = 12_000) -> [Note] {
    [Note(title: marker + String(repeating: "x", count: max(0, bytes - marker.count)))]
}

@Test("A large library wiped to empty keeps its hour, day and week anchors in the wipe save (F650)")
func aWipeKeepsTheAnchorsOfALargeLibrary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WipeByteBudget-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[Note]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0650",
        retention: RetentionPolicy(byteBudget: 30_000),
        recordCount: { $0.count }
    )

    let now = 1_757_000_000
    let weekOld = try store.save(payload("week"), now: now - 8 * 86_400)
    let dayOld = try store.save(payload("day"), expecting: weekOld.token, now: now - 2 * 86_400)
    let hourOld = try store.save(payload("hour"), expecting: dayOld.token, now: now - 2 * 3_600)
    var token = hourOld.token
    for index in 0..<2 {
        token = try store.save(payload("today \(index)"), expecting: token, now: now).token
    }
    // The wipe: a two-byte index over a library of ~12 KB generations.
    let wipe = try store.save([], expecting: token, now: now)
    #expect(wipe.token.byteCount < 100, "precondition: the wipe wrote a tiny index")

    let retained = Set(try store.retainedGenerations().map(\.name))
    for (label, outcome) in [("week", weekOld), ("day", dayOld), ("hour", hourOld)] {
        let name = try #require(outcome.retainedName)
        #expect(retained.contains(name), "the \(label) anchor was trimmed by the wipe save's budget")
    }
}

@Test("The budget's slot count cannot overflow, however the policy is configured (F650)")
func theSlotCountSaturates() {
    let policy = RetentionPolicy(recentCount: .max)
    #expect(policy.maximumKeptGenerations == .max)
    #expect(policy.effectiveByteBudget(forIndexBytes: 1) == policy.byteBudgetCeiling)
}
