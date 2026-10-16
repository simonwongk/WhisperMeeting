import Foundation
import Testing
@testable import WhisperCore

// F670 — a shred whose ledger write fails must not leave the next prune deciding on wrong dates.
//
// `shredHistory` rewrites each generation that holds a deleted meeting under a new name and then
// writes the ledger, ignoring a failure: the ledger is advisory. Since F677 a save reads a count
// back from any file the ledger does not describe, so the high-water pin keeps its counts — but the
// DATE it reads back is the file's own modification time (F234's fallback), and a rewritten file's
// was the moment of the shred. A generation a week old was then a generation a second old: no age
// anchor could hold it, and the next save pruned the copy the weekly anchor existed for. The rewrite
// now keeps the file's modification time, so the fallback reads the generation's own date.

private struct Note: Codable, Equatable { let id: String; let title: String }

private final class Armed: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.withLock { on } }
    func set(_ value: Bool) { lock.withLock { on = value } }
}

private struct LedgerWriteFailed: Error {}

@Test("A shred whose ledger write fails keeps each rewritten generation's date, so the next save's age anchors still hold it (F670)")
func aShredWhoseLedgerWriteFailsKeepsTheGenerationsDates() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F670-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerPath = root.appendingPathComponent("meetings.ledger.json").path
    let history = root.appendingPathComponent("meetings.history", isDirectory: true)
    let failLedger = Armed()
    var io = StoreFileIO.live
    io.writeAtomically = { data, url, phase in
        if failLedger.isOn, url.path == ledgerPath { throw LedgerWriteFailed() }
        try StoreFileIO.live.writeAtomically(data, url, phase)
    }
    let store = BackupJSONStore<[Note]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        io: io, recordCount: { $0.count }
    )

    // Dates are the wall clock's, because the files' own modification times are what the fallback
    // reads; each generation's file is given the date its save recorded, as a real save's would have.
    let now = Int(Date().timeIntervalSince1970)
    let secret = Note(id: "secret", title: "Board review — confidential")
    let notes = (0..<8).map { Note(id: "n\($0)", title: "meeting \($0)") }
    func save(_ value: [Note], at seconds: Int, expecting token: GenerationToken?) throws -> GenerationToken {
        let outcome = try store.save(value, expecting: token, now: seconds)
        let name = try #require(outcome.retainedName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(seconds))],
            ofItemAtPath: history.appendingPathComponent(name).path
        )
        return outcome.token
    }
    // The week-old generation is the only one holding the secret, and the age anchors are the only
    // rule keeping it: three newer saves fill the newest three, and the newest holds the most.
    var token = try save(Array(notes.prefix(2)) + [secret], at: now - 8 * 86_400, expecting: nil)
    token = try save(Array(notes.prefix(4)), at: now - 2 * 3_600, expecting: token)
    token = try save(Array(notes.prefix(5)), at: now - 60, expecting: token)
    token = try save(Array(notes.prefix(6)), at: now - 30, expecting: token)
    token = try save(Array(notes.prefix(7)), at: now - 10, expecting: token)

    failLedger.set(true)
    let shred = try store.shredHistory(removingElementsWithIDs: ["secret"])
    failLedger.set(false)
    try #require(shred.rewritten.count == 1, "fixture: only the week-old generation held the secret: \(shred.rewritten)")
    try #require(shred.rotation == nil, "fixture: the backup never held the secret, so nothing was re-saved")
    let rewrittenName = try #require(
        try FileManager.default.contentsOfDirectory(atPath: history.path).first {
            $0.hasPrefix("g-000000001-") && !shred.rewritten.contains($0)
        },
        "fixture: the rewritten generation is not on disk"
    )

    // The user keeps working.
    _ = try store.save(notes, expecting: token, now: now)

    let onDisk = try FileManager.default.contentsOfDirectory(atPath: history.path)
    #expect(
        onDisk.contains(rewrittenName),
        "the week-old generation was pruned after a shred whose ledger write failed: \(onDisk.sorted())"
    )
    let retained = try store.retainedGenerations().first { $0.name == rewrittenName }
    #expect(retained?.recordCount == 2, "the rewritten generation lost its count: \(String(describing: retained))")
    #expect(
        (retained?.wroteAtEpochSeconds).map { now - $0 >= 7 * 86_400 } == true,
        "the rewritten generation is dated \(String(describing: retained?.wroteAtEpochSeconds)), not a week ago"
    )
}
