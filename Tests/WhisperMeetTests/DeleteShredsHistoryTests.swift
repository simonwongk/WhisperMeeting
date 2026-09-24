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

// MARK: - F498: the undo the window exists for, and a queue file nobody vouched for

/// A library where "Board review" was deleted by mistake: its text is still in the history, and its
/// shred is queued.
@MainActor
private func makeMistakenDelete(_ label: String) throws -> (MeetingStore, URL, UUID) {
    let (store, root) = try makeLibrary(label)
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    store.delete(id: secret)
    try #require(store.pendingShreds.keys.contains(secret))
    return (store, root, secret)
}

private func historyHolds(_ needle: String, in root: URL) throws -> Bool {
    try allIndexText(in: root).contains { $0.key.hasPrefix("history/") && $0.value.contains(needle) }
}

@MainActor
@Test("A meeting brought back from the recovery list is not shredded a week later (F498)")
func restoredMeetingIsNotShredded() throws {
    let (store, root, secret) = try makeMistakenDelete("restored")
    defer { try? FileManager.default.removeItem(at: root) }

    // The undo F295's window exists for.
    let target = try #require(try store.indexGenerations().first { $0.recordCount == 2 })
    try store.restoreIndexGeneration(target)
    try #require(store.meetings.contains { $0.id == secret })
    let generations = Set(try store.indexGenerations().map(\.name))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded.isEmpty, "a meeting the user brought back is live, not deleted")
    #expect(store.pendingShreds.isEmpty, "its shred is cancelled, not left queued to fire later")
    // A shred re-records every generation that held the meeting under a new name, so the same
    // names still being there is the proof nothing was rewritten.
    #expect(generations.isSubset(of: Set(try store.indexGenerations().map(\.name))),
            "the generations holding a live meeting were rewritten")
    #expect(store.meetings.contains { $0.id == secret })
}

@MainActor
@Test("A meeting brought back by a whole-library restore is not shredded either (F498)")
func meetingRestoredFromABackupIsNotShredded() throws {
    let (store, root) = try makeLibrary("backup")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    // What last night's backup holds. `meetings.pending-shred.json` is not in a backup, so the
    // live queue survives the restore that replaces the index underneath it.
    let backedUp = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    store.delete(id: secret)
    try backedUp.write(to: root.appendingPathComponent("meetings.json"))
    store.reloadAfterLibraryRestore()
    try #require(store.meetings.contains { $0.id == secret })
    try #require(!store.isDegraded)
    let generations = Set(try store.indexGenerations().map(\.name))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded.isEmpty)
    #expect(store.pendingShreds.isEmpty)
    #expect(generations.isSubset(of: Set(try store.indexGenerations().map(\.name))))
}

/// `UUID(uuidString:)` reads either case, so one id spelled two ways is ONE key — and
/// `Dictionary(uniqueKeysWithValues:)` traps on it. The getter runs at every launch, from
/// `performStartupRecovery`, so the file took the app down before a window could explain anything.
@MainActor
@Test("A queue naming one meeting in two spellings is read as one entry, not a crash (F498)")
func caseVariantQueueKeysAreOneEntry() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteShred-case-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let file = #"{"\#(id.uuidString.lowercased())":1000,"\#(id.uuidString)":2000}"#
    try Data(file.utf8).write(to: root.appendingPathComponent("meetings.pending-shred.json"))

    let store = MeetingStore(rootDirectory: root)

    // The later deletion time, so the shred waits for the later of the two: nothing is lost by
    // waiting, and shredding early is the one direction that cannot be taken back.
    #expect(store.pendingShreds == [id: 2000])
}

@MainActor
@Test("A deletion time far in the past is due, and its arithmetic cannot trap (F498)")
func deletionTimeAtIntMinIsDueWithoutTrapping() throws {
    let (store, root, secret) = try makeMistakenDelete("intmin")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"\#(secret.uuidString)":\#(Int.min)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970))

    #expect(shredded == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
    #expect(store.pendingShreds.isEmpty)
}

/// A deletion dated in the future — a clock that was set wrong, a file from somewhere else — would
/// defer its shred until then, which for `Int.max` is forever. Deferring forever is itself the
/// failure: the text stays in the history the user was told it would leave.
@MainActor
@Test("A deletion dated in the future is re-dated to now, so its shred still comes (F498)")
func futureDeletionTimeIsClampedToNow() throws {
    let (store, root, secret) = try makeMistakenDelete("future")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"\#(secret.uuidString)":\#(Int.max)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))
    let now = Int(Date().timeIntervalSince1970)

    #expect(store.processPendingShreds(now: now).isEmpty, "not due yet: the window starts now")
    #expect(store.pendingShreds == [secret: now], "and it starts now, on disk")
    #expect(store.processPendingShreds(now: now + week) == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
}
