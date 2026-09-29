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
    store.clearStorageError()

    _ = store.processPendingShreds(now: now + 60)

    #expect(!String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "the copy that failed once was never looked at again")
    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("Standup"))
    #expect(store.storageErrorMessage == nil)
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

    // Brought back under its old id, as a restore or a rebuild does.
    store.upsert(original)
    store.clearStorageError()
    _ = store.processPendingShreds(now: now + 60)

    #expect(String(decoding: try Data(contentsOf: snapshot.index), as: UTF8.self).contains("confidential-kestrel"),
            "a live meeting was stripped from a copy")
    #expect(store.storageErrorMessage == nil)
}
