import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F295 — delete means delete, after a grace window. The immediate variant was tried first and
// `restoringAGenerationBringsTheLibraryBack` (F190) showed the cost: a library wiped by seventeen
// deletes could no longer be brought back. So the text stays recoverable for the retention policy's
// own week and is then scrubbed from every generation and the backup — the "Recently Deleted" shape
// every mainstream app uses. Decided 2026-09-17 under the user's delegation.

@MainActor
private func makeLibrary(_ label: String) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteShred-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MeetingStore(rootDirectory: root), root)
}

private func allIndexText(in root: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    for name in ["meetings.json", "meetings.backup.json"] {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            out[name] = try String(contentsOf: url, encoding: .utf8)
        }
    }
    let history = root.appendingPathComponent("meetings.history")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [] {
        out["history/\(name)"] = try String(contentsOf: history.appendingPathComponent(name), encoding: .utf8)
    }
    return out
}

private let week = Int(MeetingStore.shredGracePeriod)

@MainActor
@Test("Inside the grace window a deleted meeting is still in the history, so a mistaken delete can be undone (F295)")
func deletedMeetingStaysRecoverableInsideTheWindow() throws {
    let (store, root) = try makeLibrary("window")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))

    store.delete(id: secret)

    #expect(try allIndexText(in: root).values.contains { $0.contains("confidential-kestrel") })
    #expect(store.pendingShreds.keys.contains(secret))
    #expect(store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week / 2).isEmpty,
            "half a week in, nothing is due")
    // The recovery list can still bring it back.
    let target = try #require(try store.indexGenerations().first { $0.recordCount == 2 })
    try store.restoreIndexGeneration(target)
    #expect(store.meetings.contains { $0.id == secret })
}

@MainActor
@Test("After the grace window the text is gone from the index, the backup and every generation (F295)")
func deletedMeetingIsShreddedAfterTheWindow() throws {
    let (store, root) = try makeLibrary("after")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures", notes: "private note"))
    store.upsert(MeetingRecord(id: UUID(), title: "Planning", status: .completed, transcriptText: "later"))
    store.delete(id: secret)

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded == [secret])
    let after = try allIndexText(in: root)
    for (name, text) in after {
        #expect(!text.contains("confidential-kestrel"), "\(name) still holds the transcript")
        #expect(!text.contains("private note"), "\(name) still holds the notes")
        #expect(!text.contains("Board review"), "\(name) still holds the title")
    }
    // The other meetings are still in history: this is a shred, not Forget History.
    #expect(after.values.contains { $0.contains("Standup") })
    #expect(store.pendingShreds.isEmpty, "the queue entry is consumed")
    #expect(store.storageErrorMessage?.contains("could not be removed from the saved index history") != true)
    // And the store keeps working: the next save must not lose a compare-and-swap to its own rotation.
    store.upsert(MeetingRecord(id: UUID(), title: "After", status: .completed, transcriptText: "x"))
    #expect(store.storageErrorMessage == nil)
    #expect(store.meetings.count == 3)
}

@MainActor
@Test("A batch delete queues every removed meeting, and one pass shreds them all (F295)")
func batchDeleteQueuesAndShredsAll() throws {
    let (store, root) = try makeLibrary("batch")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID()
    store.upsert(MeetingRecord(id: a, title: "Alpha-secret", status: .completed, transcriptText: "alpha text"))
    store.upsert(MeetingRecord(id: b, title: "Beta-secret", status: .completed, transcriptText: "beta text"))
    store.upsert(MeetingRecord(id: UUID(), title: "Gamma", status: .completed, transcriptText: "gamma text"))

    _ = store.delete(ids: [a, b])
    #expect(Set(store.pendingShreds.keys) == [a, b])
    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(Set(shredded) == [a, b])
    let after = try allIndexText(in: root)
    #expect(!after.values.contains { $0.contains("Alpha-secret") || $0.contains("Beta-secret") })
    #expect(after.values.contains { $0.contains("Gamma") })
}

@MainActor
@Test("The queue survives a relaunch, so a shred due next week happens next week (F295)")
func pendingShredsPersistAcrossLaunches() throws {
    let (store, root) = try makeLibrary("relaunch")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed, transcriptText: "confidential-kestrel"))
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.delete(id: secret)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.pendingShreds.keys.contains(secret))
    #expect(reopened.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1) == [secret])
    #expect(!(try allIndexText(in: root).values.contains { $0.contains("confidential-kestrel") }))
}
