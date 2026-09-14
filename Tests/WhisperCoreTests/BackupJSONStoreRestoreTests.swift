import Foundation
import Testing
@testable import WhisperCore

// F190 Task 11 — restoring a retained generation. This is the payoff of the whole design: history,
// fingerprints, the ledger and the CAS all exist so that this call is safe.
//
// The guarantee F190 makes is RECOVERABILITY, not detection. Nothing in a write protocol can tell a
// valid-but-wrong generation from a valid one — `[]`, or ten blank stubs, is syntactically perfect,
// decodes cleanly, and `.complete` is an honest report of what was read. What this design promises
// is that committing such a generation cannot destroy the last real ones, and that this call brings
// one back.
//
// Restore is APPEND-ONLY: it commits the chosen bytes as a NEW generation through the ordinary
// algorithm. So a restore is itself undoable, and the bad generation stays on disk as evidence until
// it ages out. A restore that rewound the lineage in place would be one more way to lose data.
//
// Genuinely red without the fix: there is no `restore(generation:)`.

private struct Note: Codable, Equatable { let title: String }

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreRestore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func store(_ root: URL) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "aaaa0001",
        recordCount: { $0.count }
    )
}

@Test("A retained generation can be restored, and the restore is itself undoable (F190)")
func aRetainedGenerationCanBeRestored() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = store(root)

    // The incident shape, in miniature: a real library, then a valid-but-empty generation over it.
    _ = try live.save((0..<17).map { Note(title: "meeting \($0)") })
    _ = try live.save([])
    #expect(try #require(try live.load()).value.isEmpty)

    // The recovery list shows the discrimination the 2026-08-14 recovery could not make.
    let generations = try live.retainedGenerations()
    let real = try #require(
        generations.first { $0.recordCount == 17 },
        "the recovery list cannot tell 17 meetings from 0: \(generations.map(\.recordCount))"
    )

    let outcome = try live.restore(generation: real)
    #expect(try #require(try live.load()).value.count == 17)

    // Append-only: a NEW generation, not a rewind. The empty one is still on disk as evidence, and
    // the restore can itself be undone.
    #expect(outcome.token.sequence > real.sequence)
    let afterRestore = try live.retainedGenerations()
    #expect(afterRestore.contains { $0.recordCount == 0 }, "the bad generation was erased")
    #expect(afterRestore.contains { $0.fingerprint == outcome.token.fingerprint })
}

@Test("Restoring verifies the bytes against their own name and refuses a mismatch (F190)")
func restoringRefusesATamperedGeneration() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = store(root)
    _ = try live.save([Note(title: "original")])
    _ = try live.save([Note(title: "current")])

    let target = try #require(try live.retainedGenerations().first { $0.sequence == 1 })
    // Rewrite the archived file in place, so its bytes no longer match the fingerprint in its name.
    try Data(#"[{"title":"substituted"}]"#.utf8).write(
        to: root.appendingPathComponent("meetings.history").appendingPathComponent(target.name)
    )

    // Refused, not silently served. Restoring bytes that are not the ones the user picked from a
    // list is worse than refusing: they would have no way to know.
    #expect(throws: StoreHistoryError.fingerprintMismatch(target.name)) {
        _ = try live.restore(generation: target)
    }
    let stillCurrent = try #require(try live.load())
    #expect(stillCurrent.value == [Note(title: "current")])
}

@Test("Restoring a generation that decodes to nothing useful is still refused honestly (F190)")
func restoringRefusesBytesThatDoNotDecode() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = store(root)
    _ = try live.save([Note(title: "current")])

    // A file whose name is honest about its bytes, but whose bytes are not this store's type — a
    // hand-placed file, or a payload from a different schema. The fingerprint check passes and the
    // DECODE must then be what stops it, before anything is installed.
    let history = root.appendingPathComponent("meetings.history", isDirectory: true)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let bytes = Data(#"{"not":"an array of notes"}"#.utf8)
    let name = "g-000000009-\(StoreFingerprint.of(bytes)).json"
    try bytes.write(to: history.appendingPathComponent(name), options: .atomic)

    let entry = try #require(try live.retainedGenerations().first { $0.name == name })
    #expect(throws: (any Error).self) { _ = try live.restore(generation: entry) }
    let unchanged = try #require(try live.load())
    #expect(unchanged.value == [Note(title: "current")])
}
