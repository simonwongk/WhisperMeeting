import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F668 — F457's week-later shred of the index's side copies (quarantined copies, a restore's
// snapshot) had three holes, all found by lane C's first independent review (probes P2 and P5):
//
// - A copy that is not valid JSON — a torn or corrupt file, which is usually why it was quarantined
//   — was skipped without a word while it still held the deleted meeting, and the id then left the
//   queue, so nothing ever looked again.
// - A copy that could not be rewritten once (a transient permission refusal) was reported once and
//   dropped the same way.
// - The report named the file only, so `.pre-restore-…/meetings.json` read as the live index.
//
// Deferred, never destructive: a copy the shred cannot clean stays queued and is looked at again,
// and one it cannot parse is reported rather than deleted — it was kept so someone could recover
// from it.

private let week = Int(MeetingStore.shredGracePeriod)

@MainActor
private func makeLibraryWithADeletedMeeting(_ label: String) throws -> (MeetingStore, URL, UUID, Data) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F668-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    let index = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    return (store, root, secret, index)
}

@MainActor
@Test("A side copy that is not a readable index but still holds the deleted meeting is reported by its path, and again at the next launch (F668)")
func unparseableSideCopyIsReportedAndStaysQueued() throws {
    let (store, root, secret, index) = try makeLibraryWithADeletedMeeting("torn")
    defer { try? FileManager.default.removeItem(at: root) }
    // A torn write: no longer a JSON array, still holding the text.
    let quarantine = root.appendingPathComponent("meetings.unreadable-20260901T100000Z.json")
    try index.prefix(index.count - 40).write(to: quarantine)
    store.delete(id: secret)
    store.clearStorageError()   // the entry-only delete's own message, unrelated to the shred
    let now = Int(Date().timeIntervalSince1970) + week + 1

    #expect(store.processPendingShreds(now: now) == [secret])

    let message = try #require(store.storageErrorMessage, "the deleted meeting's text was left in a copy without a word")
    #expect(message.contains("meetings.unreadable-20260901T100000Z.json"), "\(message)")
    #expect(FileManager.default.fileExists(atPath: quarantine.path), "a copy kept for recovery was deleted")
    #expect(String(decoding: try Data(contentsOf: quarantine), as: UTF8.self).contains("confidential-kestrel"),
            "fixture: the copy cannot be rewritten, so the text is still in it")
    // What keeps it queued is a key an earlier build's reader (F498's, verbatim) drops, so an
    // earlier build neither trips on it nor shreds the history a second time.
    let raw = try JSONDecoder().decode(
        [String: Int].self, from: Data(contentsOf: root.appendingPathComponent("meetings.pending-shred.json"))
    )
    #expect(raw.keys.contains { $0.hasSuffix(secret.uuidString) }, "nothing keeps the copy queued: \(raw)")
    let earlierBuild = Dictionary(
        raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
        uniquingKeysWith: max
    )
    #expect(earlierBuild.isEmpty)

    // The next launch looks again, and says so again, because the text is still there.
    let relaunched = MeetingStore(rootDirectory: root)
    _ = relaunched.processPendingShreds(now: now + 60)
    #expect(relaunched.storageErrorMessage?.contains("meetings.unreadable-20260901T100000Z.json") == true,
            "the id left the queue, so nothing will ever look at that copy again")

    // Once the user removes the copy, the queue lets go and nothing more is said.
    try FileManager.default.removeItem(at: quarantine)
    let afterRemoval = MeetingStore(rootDirectory: root)
    _ = afterRemoval.processPendingShreds(now: now + 120)
    #expect(afterRemoval.storageErrorMessage == nil)
    let later = MeetingStore(rootDirectory: root)
    _ = later.processPendingShreds(now: now + 180)
    #expect(later.storageErrorMessage == nil, "the queue did not let go once the copy was gone")
}

@MainActor
private func makeSnapshot(_ root: URL, index: Data) throws -> (folder: URL, index: URL) {
    let folder = root.appendingPathComponent(".pre-restore-1790000000", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let snapshotIndex = folder.appendingPathComponent("meetings.json")
    try index.write(to: snapshotIndex)
    return (folder, snapshotIndex)
}

@MainActor
@Test("A side copy that could not be rewritten is named by its path in the library and retried until it is clean (F668)")
func failedSideCopyRewriteIsRetried() throws {
    let (store, root, secret, index) = try makeLibraryWithADeletedMeeting("stuck")
    let snapshot = try makeSnapshot(root, index: index)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)
        try? FileManager.default.removeItem(at: root)
    }
    store.delete(id: secret)
    store.clearStorageError()
    // A transient refusal: the snapshot folder is read-only for this one pass.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshot.folder.path)
    let now = Int(Date().timeIntervalSince1970) + week + 1

    #expect(store.processPendingShreds(now: now) == [secret])

    let message = try #require(store.storageErrorMessage)
    #expect(message.contains(".pre-restore-1790000000/meetings.json"),
            "named by its file name alone, a snapshot's copy reads as the live index: \(message)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)

    // Retried at the next launch (each pending id is tried once per launch: review round 2).
    let relaunched = MeetingStore(rootDirectory: root)
    _ = relaunched.processPendingShreds(now: now + 60)

    #expect(!String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "the copy that failed once was never looked at again")
    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("Standup"))
    #expect(relaunched.storageErrorMessage == nil)
}

/// A new deletion has its own week (review round 2, probe P3). A meeting whose side copies were still
/// queued from an earlier deletion, brought back and deleted again before any pass saw it live, kept
/// the old `side-copies:` entry — so the next pass stripped the side copies at once, inside the new
/// deletion's week.
@MainActor
@Test("Deleting a meeting again starts a new week for its side copies too (F668)")
func redeleteStartsANewWeekForSideCopies() throws {
    let (store, root, secret, index) = try makeLibraryWithADeletedMeeting("redelete")
    let snapshot = try makeSnapshot(root, index: index)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)
        try? FileManager.default.removeItem(at: root)
    }
    let original = try #require(store.meeting(id: secret))
    store.delete(id: secret)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshot.folder.path)
    let now = Int(Date().timeIntervalSince1970) + week + 1
    #expect(store.processPendingShreds(now: now) == [secret])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)

    store.upsert(original)   // back under its old id, with no pass in between
    store.delete(id: secret) // and deleted again, today
    store.clearStorageError()

    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "the second deletion stripped the snapshot at once, inside its own week")
    // And a launch an hour into the new week leaves it too.
    let redeletedAt = try #require(store.pendingShreds[secret])
    let relaunched = MeetingStore(rootDirectory: root)
    _ = relaunched.processPendingShreds(now: redeletedAt + 3_600)
    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "the old side-copy entry outlived the new deletion")
}

/// A copy that cannot be read says nothing about what it holds (review round 2, probe P4). It was
/// treated as holding every pending deletion, so it kept each later deletion queued for good and
/// every launch said it still held text it may never have held.
@MainActor
@Test("A copy that cannot be read is reported, but holds no deletion in the queue (F668)")
func unreadableCopyHoldsNoDeletion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F668-unreadable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let copy = root.appendingPathComponent("meetings.unreadable-20200101T000000Z.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        try? FileManager.default.removeItem(at: root)
    }
    try Data("[]".utf8).write(to: copy)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copy.path)
    let store = MeetingStore(rootDirectory: root)
    var ids: [UUID] = []
    for title in ["One", "Two", "Three"] {
        let id = UUID()
        ids.append(id)
        store.upsert(MeetingRecord(id: id, title: title, status: .completed))
    }
    store.delete(ids: ids)
    store.clearStorageError()

    #expect(Set(store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)) == Set(ids))

    let raw = (try? JSONDecoder().decode(
        [String: Int].self, from: Data(contentsOf: root.appendingPathComponent("meetings.pending-shred.json"))
    )) ?? [:]
    #expect(raw.isEmpty, "a copy nobody could read keeps \(raw.count) deletions queued")
    let message = try #require(store.storageErrorMessage, "a copy that could not be checked was not mentioned")
    #expect(message.contains("meetings.unreadable-20200101T000000Z.json"), "\(message)")
    #expect(!message.contains("could not be removed from"), "it claims the copy held text: \(message)")
}

/// "Said once per launch, not after every delete" (review round 2: dropping the check that says it
/// left every test green). Two deletions come due in two passes of one session, and the same
/// unreadable-as-an-index copy names both: the second pass must not say it again.
@MainActor
@Test("A copy that stays stuck is reported once per launch, not again at the next delete's pass (F668)")
func stuckCopyIsReportedOncePerLaunch() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F668-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let first = UUID(), second = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: first, title: "First secret", status: .completed))
    store.upsert(MeetingRecord(id: second, title: "Second secret", status: .completed))
    let index = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    let quarantine = root.appendingPathComponent("meetings.unreadable-20260901T100000Z.json")
    try (index + Data("torn".utf8)).write(to: quarantine)   // names both, and is not JSON
    store.delete(id: first)
    let firstDeleted = try #require(store.pendingShreds[first])
    store.clearStorageError()

    #expect(store.processPendingShreds(now: firstDeleted + week) == [first])
    let message = try #require(store.storageErrorMessage)
    #expect(message.contains("meetings.unreadable-20260901T100000Z.json"), "\(message)")
    store.clearStorageError()

    store.delete(id: second)
    store.clearStorageError()
    let secondDeleted = try #require(store.pendingShreds[second])
    #expect(store.processPendingShreds(now: secondDeleted + week) == [second])
    #expect(store.storageErrorMessage == nil, "the same stuck copy was reported twice in one launch")

    let relaunched = MeetingStore(rootDirectory: root)
    _ = relaunched.processPendingShreds(now: secondDeleted + week + 60)
    #expect(relaunched.storageErrorMessage?.contains("meetings.unreadable-20260901T100000Z.json") == true,
            "the next launch must say it again: the text is still there")
}

/// F498's rule reaches the retry too: a meeting that is live again is never stripped from a copy.
@MainActor
@Test("A meeting brought back before a retry is not stripped from the copy that failed (F668)")
func retryLeavesAMeetingThatCameBack() throws {
    let (store, root, secret, index) = try makeLibraryWithADeletedMeeting("back")
    let snapshot = try makeSnapshot(root, index: index)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)
        try? FileManager.default.removeItem(at: root)
    }
    let original = try #require(store.meeting(id: secret))
    store.delete(id: secret)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshot.folder.path)
    let now = Int(Date().timeIntervalSince1970) + week + 1
    #expect(store.processPendingShreds(now: now) == [secret])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.folder.path)

    // Brought back under its old id, as a restore or a rebuild does — and the retry comes at the
    // next launch, which sees it live.
    store.upsert(original)
    let relaunched = MeetingStore(rootDirectory: root)
    _ = relaunched.processPendingShreds(now: now + 60)

    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "a live meeting was stripped from a copy")
    #expect(relaunched.storageErrorMessage == nil)
}
