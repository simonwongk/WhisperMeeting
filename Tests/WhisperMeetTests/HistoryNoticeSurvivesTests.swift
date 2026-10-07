import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F669 — F553's once-per-session "earlier versions cannot be kept" notice is held in
// `historyNoticeAwaitingDismissal` until the alert's OK, and shown through `storageErrorMessage`.
// Two paths that own that message erased it: a lost race's reload set the message to nil, so the
// notice left the screen unread until some later save put it back; and the alert's OK on a DIFFERENT
// storage message released the notice as if it had been read, so it was gone for the session. The
// notice is its own fact; the message is only where it is shown (AGENTS.md: "a fact nothing else owns
// cannot be erased by a path that owns a message").

@MainActor
private func squattedLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F669-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // F553's reproduction: a plain file where the history folder should be.
    try Data("not a directory".utf8).write(to: root.appendingPathComponent("meetings.history"))
    return root
}

@MainActor
@Test("A lost race does not take the unread history notice off screen (F669)")
func lostRaceKeepsTheHistoryNotice() throws {
    let root = try squattedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Standup", status: .completed))
    let notice = try #require(store.storageErrorMessage, "fixture: the squatted history raises F553's notice")
    try #require(notice.contains("meetings.history"))
    // Another copy renames the meeting first, so this window's rename loses.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count }
    )
    let seen = try #require(try rival.load())
    _ = try rival.save(seen.value.map { var r = $0; r.title = "Standup, theirs"; return r }, expecting: seen.token)

    store.update(id: id) { $0.title = "Standup, mine" }

    try #require(store.conflictOffer != nil, "fixture: the rename lost and was offered back")
    #expect(store.storageErrorMessage == notice, "the reload took the unread notice off screen")
}

@MainActor
@Test("OK on a different storage message does not count as reading the history notice (F669)")
func okOnAnotherMessageKeepsTheHistoryNotice() throws {
    let root = try squattedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let kept = UUID(), doomed = UUID()
    store.upsert(MeetingRecord(id: kept, title: "Standup", status: .completed))
    let notice = try #require(store.storageErrorMessage, "fixture: the squatted history raises F553's notice")
    // A delete whose recording path is not the meeting's own folder removes the entry only, and says
    // so — a second storage message, put up over the unread notice.
    store.upsert(MeetingRecord(id: doomed, title: "Stray", recordingPath: "none", status: .completed))
    #expect(store.delete(ids: [doomed]) == [doomed])
    let other = try #require(store.storageErrorMessage)
    try #require(other != notice, "fixture: the delete's own message is up")

    store.clearStorageError()   // the alert's OK, on the delete's message

    #expect(store.storageErrorMessage == notice, "the OK on another message released the unread notice")
    store.update(id: kept) { $0.title = "Standup, renamed" }
    #expect(store.storageErrorMessage == notice, "the notice was gone for the rest of the session")

    store.clearStorageError()   // now the notice itself is read
    #expect(store.storageErrorMessage == nil)
    store.update(id: kept) { $0.title = "Standup, renamed again" }
    #expect(store.storageErrorMessage == nil, "the notice came back after it was read")
}
