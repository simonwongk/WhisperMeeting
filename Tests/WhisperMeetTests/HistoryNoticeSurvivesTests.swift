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

/// A store showing F553's notice under another storage message: the notice is unread, and the
/// message on screen is the delete's.
@MainActor
private func noticeUnderAnotherMessage(_ root: URL) throws -> (MeetingStore, UUID, String) {
    let store = MeetingStore(rootDirectory: root)
    let kept = UUID(), doomed = UUID()
    store.upsert(MeetingRecord(id: kept, title: "Standup", status: .completed))
    let notice = try #require(store.storageErrorMessage, "fixture: the squatted history raises F553's notice")
    // A delete whose recording path is not the meeting's own folder removes the entry only, and says
    // so — a second storage message, put up over the unread notice.
    store.upsert(MeetingRecord(id: doomed, title: "Stray", recordingPath: "none", status: .completed))
    try #require(store.delete(ids: [doomed]) == [doomed])
    let other = try #require(store.storageErrorMessage)
    try #require(other != notice, "fixture: the delete's own message is up")
    return (store, kept, notice)
}

/// The notice comes back on the turn after a dismissal, not inside it (F669). Polled with a large
/// cap: the subject of the wait is the very thing asserted.
@MainActor
private func waitForMessage(_ store: MeetingStore, _ expected: String) async throws {
    let deadline = Date().addingTimeInterval(10)
    while store.storageErrorMessage != expected, Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(store.storageErrorMessage == expected, "the unread notice did not come back")
}

@MainActor
@Test("OK on a different storage message does not count as reading the history notice (F669)")
func okOnAnotherMessageKeepsTheHistoryNotice() async throws {
    let root = try squattedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, kept, notice) = try noticeUnderAnotherMessage(root)

    store.clearStorageError()   // the alert's OK, on the delete's message

    try await waitForMessage(store, notice)
    store.update(id: kept) { $0.title = "Standup, renamed" }
    #expect(store.storageErrorMessage == notice, "the notice was gone for the rest of the session")

    store.clearStorageError()   // now the notice itself is read
    #expect(store.storageErrorMessage == nil)
    store.update(id: kept) { $0.title = "Standup, renamed again" }
    #expect(store.storageErrorMessage == nil, "the notice came back after it was read")
}

/// The review of F669 found the window's one OK calling `clearStorageError()` twice — the button's
/// action and the alert's `isPresented` setter — and the second call released the notice the first
/// had just put back. The alert now clears once (`alertClearsStorageOncePerDismissal`); this pins
/// the store's side, so a second call in the same dismissal cannot undo the first either.
@MainActor
@Test("Two clears in one dismissal of another message leave the history notice unread (F669)")
func twoClearsInOneDismissalKeepTheHistoryNotice() async throws {
    let root = try squattedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, _, notice) = try noticeUnderAnotherMessage(root)

    store.clearStorageError()
    store.clearStorageError()   // the same dismissal, a second time

    try await waitForMessage(store, notice)
    store.clearStorageError()   // the notice's own OK
    #expect(store.storageErrorMessage == nil)
}

/// The window cannot be rendered here (F174), so the alert's single clear is pinned on source,
/// comments stripped (F285): within the root `.alert("WhisperMeet", …)` up to its message, exactly one
/// `clearStorageError()`, in the `isPresented` setter, and an OK button that does nothing itself.
@Test("The window's alert clears the storage message once per dismissal (F669)")
func alertClearsStorageOncePerDismissal() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let title = try #require(source.range(of: "\"WhisperMeet\",\n"), "the root alert's title moved")
    let end = try #require(source[title.upperBound...].range(of: "} message: {"), "the alert's message moved")
    let alert = source[title.upperBound..<end.lowerBound]
    #expect(alert.components(separatedBy: "clearStorageError()").count - 1 == 1, "\(alert)")
    #expect(alert.contains("set: {"), "the clear is no longer in the isPresented setter")
    #expect(alert.contains("Button(\"OK\") { }"), "the OK button clears again; one OK would clear twice")
}
