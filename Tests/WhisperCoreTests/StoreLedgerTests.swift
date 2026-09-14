import Foundation
import Testing
@testable import WhisperCore

// F190 Task 4 — the commit record, and Invariant L.
//
// > A ledger that is missing, unreadable, undecodable, or carries an unknown `formatVersion` is
// > treated as NO LEDGER, and the store behaves exactly as it did before F190.
//
// This is the invariant the whole recovery design rests on, and four separate requirements fail
// together if it is ever relaxed:
//
//   - a restore that brings back `meetings.json` without its ledger must read `.complete`, not damaged;
//   - `docs/RECOVERY.md` tells the user to hand-copy index files, and a hand-copy must never brick
//     the library;
//   - deleting the ledger is the documented manual exit from a divergence read-only state;
//   - an old bundle that writes the two legacy files and knows nothing about the ledger must not be
//     destructive.
//
// So it is tested per input shape, not asserted once and commented. Genuinely red without the fix:
// `StoreLedger` does not exist.

private func makeLedgerDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreLedgerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func sampleLedger(sequence: UInt64 = 1) -> StoreLedger {
    let record = StoreLedger.Record(
        sequence: sequence,
        fingerprint: "0123456789abcdef",
        byteCount: 42,
        writer: "a1b2c3d4",
        wroteAtEpochSeconds: 1_757_000_000,
        parentFingerprint: nil,
        recordCount: 3,
        historyName: "g-0001-0123456789abcdef.json"
    )
    return StoreLedger(
        formatVersion: StoreLedger.currentFormatVersion,
        current: record,
        previous: nil,
        history: [record],
        historyAvailable: true,
        writerRealm: "uid-501"
    )
}

@Test("A ledger round-trips through its own reader and writer (F190)")
func storeLedgerRoundTrips() throws {
    let directory = try makeLedgerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.ledger.json")

    #expect(try StoreLedger.write(sampleLedger(), to: url) == .written)
    #expect(StoreLedger.read(at: url) == sampleLedger())
}

@Test("Invariant L: every unusable ledger shape reads as no ledger at all (F190)")
func invariantLTreatsEveryUnusableLedgerAsAbsent() throws {
    let directory = try makeLedgerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let unusable: [(String, Data?)] = [
        ("absent — nothing was ever written", nil),
        ("zero bytes — an interrupted write", Data()),
        ("invalid JSON — a torn write", Data("{\"formatVersion\":".utf8)),
        // Fully valid in every OTHER respect — same shape this build writes, only the version
        // differs — so the version fence is the only thing that can reject it. An earlier draft used
        // `"current":{}` here and passed even with the fence removed, because the decode failed
        // first: the case proved nothing and looked like it proved everything.
        ("valid JSON, unknown formatVersion — written by a newer build",
         Data(#"{"current":{"byteCount":42,"fingerprint":"0123456789abcdef","sequence":1,"wroteAtEpochSeconds":1757000000,"writer":"a1b2c3d4"},"formatVersion":9999,"history":[],"historyAvailable":true,"writerRealm":"none"}"#.utf8)),
        ("valid JSON, wrong shape — something else entirely", Data(#"{"hello":"world"}"#.utf8)),
        ("valid JSON, right version, missing required fields",
         Data(#"{"formatVersion":1}"#.utf8)),
    ]

    for (name, bytes) in unusable {
        let url = directory.appendingPathComponent("case-\(UUID().uuidString).ledger.json")
        if let bytes { try bytes.write(to: url, options: .atomic) }
        #expect(StoreLedger.read(at: url) == nil, "\(name): should have read as no ledger")
    }
}

@Test("A ledger from a newer build is never overwritten (F190)")
func aNewerFormatVersionIsNotOverwritten() throws {
    let directory = try makeLedgerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.ledger.json")

    // Invariant L says a newer ledger reads as absent. It must not ALSO be clobbered: the forward
    // fence is cheap and it is on metadata only, so a user who downgrades the app once does not
    // lose the newer build's commit record permanently.
    let fromTheFuture = Data(#"{"formatVersion":9999,"anything":true}"#.utf8)
    try fromTheFuture.write(to: url, options: .atomic)

    #expect(StoreLedger.read(at: url) == nil)
    #expect(try StoreLedger.write(sampleLedger(), to: url) == .refusedNewerFormat)
    #expect(try Data(contentsOf: url) == fromTheFuture, "the newer build's ledger was overwritten")
}

@Test("A hostile ledger beside a healthy index changes nothing about loading it (F190)")
func aHostileLedgerDoesNotDisturbTheStore() throws {
    let directory = try makeLedgerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    let ledgerURL = directory.appendingPathComponent("meetings.ledger.json")

    // The load-bearing half of Invariant L, stated against the real store rather than the codec:
    // whatever is in that file, the library still opens complete and writable. This test must keep
    // passing once the store starts consulting the ledger — that is the whole point of it.
    struct Note: Codable, Equatable { let title: String }
    let store = BackupJSONStore<[Note]>(primaryURL: primaryURL, backupURL: backupURL)
    try store.save([Note(title: "First")])

    for bytes in [Data(), Data("garbage".utf8),
                  Data(#"{"formatVersion":9999}"#.utf8),
                  Data(#"{"formatVersion":1,"current":{"sequence":77,"fingerprint":"deadbeefdeadbeef","byteCount":999999,"writer":"zzzzzzzz","wroteAtEpochSeconds":0},"history":[],"historyAvailable":true,"writerRealm":"none"}"#.utf8)] {
        try bytes.write(to: ledgerURL, options: .atomic)
        let loaded = try #require(try store.load())
        #expect(loaded.health == .complete, "a ledger of \(bytes.count) bytes made the library damaged")
        #expect(loaded.value == [Note(title: "First")])
        try store.save([Note(title: "Second")])
        #expect(try #require(try store.load()).value == [Note(title: "Second")])
        try store.save([Note(title: "First")])
    }
}
