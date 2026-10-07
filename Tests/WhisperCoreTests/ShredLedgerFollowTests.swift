import Foundation
import Testing
@testable import WhisperCore

// F649 — the shred's ledger records follow their own file, not whichever file shares their bytes.
//
// `shredHistory` rewrites every retained generation that holds a deleted meeting under a new
// content-addressed name, and the ledger's records follow so the high-water pin keeps the counts it
// reads by name. They used to follow by FINGERPRINT: two generations with the same bytes — content
// that went A, B, A, both copies still on disk while A is the backup — share one fingerprint and one
// record, which names the newer file. When the listing returned the older file first, its rewrite
// re-fingerprinted that record while leaving it named after the newer file; the newer file's own
// rewrite then found no record with the old fingerprint, renamed itself, and the record was left
// naming a file that no longer existed. The pin lost its count, moved to a smaller generation, and
// both copies of the largest library were pruned. Which file the listing returns first is up to
// `readdir`, so the listing is fixed here in both orders.

private struct Note: Codable, Equatable { let id: String; let title: String }

private struct Fixture {
    let directory: URL
    var primaryURL: URL { directory.appendingPathComponent("meetings.json") }
    var backupURL: URL { directory.appendingPathComponent("meetings.backup.json") }
    var ledgerURL: URL { directory.appendingPathComponent("meetings.ledger.json") }
    var historyURL: URL { directory.appendingPathComponent("meetings.history", isDirectory: true) }
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShredLedgerFollow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fixture(directory: directory)
}

/// A store whose history listing comes back sorted, oldest name first or newest name first.
private func makeStore(_ fixture: Fixture, oldestFirst: Bool) -> BackupJSONStore<[Note]> {
    var io = StoreFileIO.live
    io.contentsOfDirectory = { url, phase in
        let names = try StoreFileIO.live.contentsOfDirectory(url, phase)
        guard phase == .listHistory else { return names }
        return oldestFirst ? names.sorted() : names.sorted(by: >)
    }
    return BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL, io: io,
        writer: "aaaa0649", recordCount: { $0.count }
    )
}

/// The element counts of every generation FILE on disk, decoded from its bytes — never the ledger,
/// which is the thing under test.
private func countsOnDisk(_ fixture: Fixture) -> [Int] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)) ?? [])
        .filter { $0.hasPrefix("g-") }
    return names.compactMap { name in
        guard let data = try? Data(contentsOf: fixture.historyURL.appendingPathComponent(name)),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else { return nil }
        return notes.count
    }.sorted()
}

@Test(
    "A shred leaves the pin's record on the file it describes, whichever copy of equal content is listed first (F649)",
    arguments: [true, false]
)
func theShredKeepsThePinsRecordOnItsOwnFile(oldestFirst: Bool) throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture, oldestFirst: oldestFirst)
    // Every save at one instant, so no age anchor holds anything: the pin is the only rule keeping
    // the largest library once it leaves the newest three.
    let now = 1_757_000_000
    let meetings = (0..<17).map { Note(id: "m\($0)", title: "meeting \($0)") }
    let secret = Note(id: "secret", title: "Board review — confidential")
    let full = meetings + [secret]                        // eighteen, with the meeting to be shredded
    let edited = Array(meetings.dropFirst()) + [secret]   // seventeen

    var token = try store.save(full, now: now).token                      // g-1: A
    token = try store.save(edited, expecting: token, now: now).token      // g-2: B
    token = try store.save(full, expecting: token, now: now).token        // g-3: A again — one record, naming g-3
    token = try store.save([], expecting: token, now: now).token          // g-4: the wipe; A is now the backup
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)
        .filter { $0.hasPrefix("g-") }
    try #require(before.count == 4, "precondition: both copies of A are on disk while A is live: \(before.sorted())")

    let shred = try store.shredHistory(removingElementsWithIDs: ["secret"])
    try #require(shred.rewritten.count == 3, "A twice and B held the meeting: \(shred.rewritten)")

    // What the pin and the recovery list read: the seventeen meetings left in A are still counted.
    let retained = try store.retainedGenerations()
    #expect(
        retained.contains { $0.recordCount == 17 },
        "no retained generation is counted at seventeen: \(retained.map { "\($0.name)=\($0.recordCount.map(String.init) ?? "nil")" })"
    )
    // And no record names a file the shred renamed away.
    let ledger = try #require(StoreLedger.read(at: fixture.ledgerURL))
    let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path))
    let renamedAway = Set(before).subtracting(onDisk)
    let dangling = ledger.history.compactMap(\.historyName).filter { renamedAway.contains($0) }
    #expect(dangling.isEmpty, "records still name files the shred removed: \(dangling)")

    // The user keeps working: three more saves push A's copies out of the newest three.
    for index in 0..<3 {
        token = try store.save([Note(id: "s\(index)", title: "after \(index)")], expecting: token, now: now).token
    }
    #expect(
        countsOnDisk(fixture).contains(17),
        "the pinned library was pruned after the shred: counts on disk \(countsOnDisk(fixture))"
    )
}
