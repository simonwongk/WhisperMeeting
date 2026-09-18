import Foundation
import Testing
@testable import WhisperCore

// F295 — delete means delete. Retained generations hold every meeting's text so a bad save can be
// undone; a deleted meeting's text therefore survived in them until they aged out, and in the
// high-water generation indefinitely. The decision (2026-09-17, whisper-37, under the user's
// delegation): shred automatically, per meeting. Each generation that holds the record is
// re-recorded WITHOUT it under a new content-addressed name with the same sequence, and the ledger
// follows; a generation that never held it is not touched, which is what keeps this from being a
// blunt "forget everything" and keeps the undo protection for every other meeting.

private struct Note: Codable, Equatable { let id: String; let title: String }

private func makeStore() throws -> (BackupJSONStore<[Note]>, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F295-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BackupJSONStore<[Note]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        recordCount: { $0.count }
    )
    return (store, root)
}

private func everyHistoryFile(_ root: URL) throws -> [String: String] {
    let directory = root.appendingPathComponent("meetings.history")
    var out: [String: String] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
        out[name] = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
    return out
}

@Test("A shredded record is absent from every retained generation afterwards (F295)")
func shredRemovesTheRecordFromEveryGeneration() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = Note(id: "s", title: "Board review — confidential")
    let keep = Note(id: "k", title: "Standup")
    try store.save([keep], now: 1)
    try store.save([keep, secret], now: 2)
    try store.save([keep, secret, Note(id: "m", title: "Planning")], now: 3)
    // The delete itself, as the app does it: a save without the record.
    try store.save([keep, Note(id: "m", title: "Planning")], now: 4)
    #expect(try everyHistoryFile(root).values.contains { $0.contains("confidential") })

    let rewritten = try store.rewriteHistory { notes in
        let kept = notes.filter { $0.id != "s" }
        return kept.count == notes.count ? nil : kept
    }

    #expect(rewritten.count == 2, "exactly the two generations that held the record: \(rewritten)")
    let after = try everyHistoryFile(root)
    #expect(!after.values.contains { $0.contains("confidential") })
    // And the backup copy, which is the previous generation, no longer holds it either.
    let backup = try String(contentsOf: root.appendingPathComponent("meetings.backup.json"), encoding: .utf8)
    #expect(!backup.contains("confidential"))
}

@Test("A generation that never held the record is left byte-for-byte alone (F295)")
func shredLeavesUntouchedGenerationsAlone() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save([Note(id: "k", title: "Standup")], now: 1)
    try store.save([Note(id: "k", title: "Standup"), Note(id: "s", title: "Secret")], now: 2)
    try store.save([Note(id: "k", title: "Standup")], now: 3)
    let before = try everyHistoryFile(root)

    let rewritten = try store.rewriteHistory { notes in
        let kept = notes.filter { $0.id != "s" }
        return kept.count == notes.count ? nil : kept
    }

    let after = try everyHistoryFile(root)
    #expect(rewritten.count == 1)
    // Every file that did not hold the secret is still there under its old name with its old bytes.
    for (name, bytes) in before where !bytes.contains("Secret") {
        #expect(after[name] == bytes, "\(name) should be untouched")
    }
}

@Test("A rewritten generation keeps its sequence, gets a new fingerprint, and is still restorable (F295)")
func shredKeepsGenerationsRestorable() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save([Note(id: "k", title: "Standup"), Note(id: "s", title: "Secret")], now: 1)
    try store.save([Note(id: "k", title: "Standup"), Note(id: "s", title: "Secret"), Note(id: "m", title: "More")], now: 2)
    try store.save([Note(id: "k", title: "Standup"), Note(id: "m", title: "More")], now: 3)
    let sequencesBefore = try store.retainedGenerations().map(\.sequence).sorted()

    _ = try store.rewriteHistory { notes in
        let kept = notes.filter { $0.id != "s" }
        return kept.count == notes.count ? nil : kept
    }

    let generations = try store.retainedGenerations()
    #expect(Set(generations.map(\.sequence)).isSuperset(of: Set(sequencesBefore)))
    // Every generation still verifies against its own name and decodes: `data(of:)` refuses a
    // mismatch, and the ledger's record counts followed the rewrite.
    for generation in generations {
        #expect(generation.bytesMatchName, Comment(rawValue: generation.name))
        let notes = try JSONDecoder().decode([Note].self, from: try store.data(of: generation))
        #expect(!notes.contains { $0.id == "s" })
    }
    let oldest = try #require(generations.min { $0.sequence < $1.sequence })
    #expect(oldest.recordCount == 1, "the ledger's count for the rewritten generation follows: \(String(describing: oldest.recordCount))")
    _ = try store.restore(generation: oldest)
    #expect(try store.load()?.value == [Note(id: "k", title: "Standup")])
}
