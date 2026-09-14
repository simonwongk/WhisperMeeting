import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F190 Task 10 — threading generation tokens through the store. Without this the compare-and-swap
// never fires: every save would pass `expecting: nil`, which is the compatibility default meaning
// last-writer-wins, and the whole transaction layer would sit in the tree doing nothing.
//
// The other half is the CHANNEL. A save-time race must not touch `health`, because
// `AppModel.startRecording` pre-flights `!store.isDegraded` and relies on that answer for the whole
// recording — a mid-session degrade would make `stopRecording`'s `upsert` silently return and lose a
// finished meeting. So a conflict goes to `writeConflict`/`unsavedChanges` and health stays put.
//
// Genuinely red without the fix: there is no `writeConflict`, no `unsavedChanges`, no
// `persistCommitCount`, and no token is threaded anywhere.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingStoreGeneration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(_ title: String) -> MeetingRecord {
    MeetingRecord(id: UUID(), title: title, recordingPath: "none", status: .recorded)
}

/// A rival writer over the same files, committing a full F190 generation — an old bundle, a second
/// app instance, or a hand-restore that went through the store.
@MainActor
private func foreignWriterCommits(_ titles: [String], in root: URL) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let existing = try rival.load()
    _ = try rival.save(titles.map { meeting($0) }, expecting: existing?.token)
}

@Test("A successful save refreshes the token, so consecutive saves keep working (F190)")
@MainActor
func aSuccessfulSaveRefreshesTheToken() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    // If the token were seeded once and never refreshed, the SECOND save would carry a token
    // describing the first generation and conflict with its own predecessor.
    store.upsert(meeting("one"))
    #expect(store.storageErrorMessage == nil)
    store.upsert(meeting("two"))
    store.upsert(meeting("three"))

    #expect(store.storageErrorMessage == nil, "a store conflicted with its own previous save")
    #expect(store.writeConflict == nil)
    #expect(!store.unsavedChanges)
    #expect(store.meetings.count == 3)
    #expect(store.persistCommitCount == 3)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meetings.count == 3)
    #expect(reopened.health == .complete)
}

@Test("A rival writer's commit is refused, reported, and the refused body is preserved (F190)")
@MainActor
func aRivalCommitIsRefusedAndTheBodyPreserved() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("shared base"))

    // A fresh store, holding the token for the generation it just read.
    let store = MeetingStore(rootDirectory: root)
    #expect(store.health == .complete)
    let attemptedBefore = store.persistCount
    let committedBefore = store.persistCommitCount

    try foreignWriterCommits(["the rival's library"], in: root)

    store.upsert(meeting("our edit"))

    // Refused, and SAID SO. Today the most destructive save failure in the app produces no
    // user-visible message at all.
    #expect(store.writeConflict != nil, "a lost race was not reported to the user")
    #expect(store.unsavedChanges, "the user's unsaved edit was not flagged")
    #expect(store.storageErrorMessage != nil)

    // Health is UNTOUCHED. This is the load-bearing part: a mid-session degrade would make
    // `stopRecording`'s upsert silently return and lose a finished meeting.
    #expect(store.health == .complete)
    #expect(!store.isDegraded)

    // "Attempted" still counts the attempt; only commits count the commit.
    #expect(store.persistCount == attemptedBefore + 1)
    #expect(store.persistCommitCount == committedBefore)

    // Neither update is lost: the rival's generation is live, and our body is on disk as a branch.
    let live = try #require(
        try BackupJSONStore<[MeetingRecord]>(
            primaryURL: root.appendingPathComponent("meetings.json"),
            backupURL: root.appendingPathComponent("meetings.backup.json")
        ).load()
    )
    #expect(live.value.map(\.title) == ["the rival's library"])
    let branches = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("meetings.history").path
    ).filter { $0.hasPrefix("conflict-") }
    #expect(branches.count == 1, "the refused edit was discarded instead of preserved")
}

@Test("A recovered save clears the conflict report and the unsaved flag (F190)")
@MainActor
func aRecoveredSaveClearsTheConflictReport() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base"))
    let store = MeetingStore(rootDirectory: root)
    try foreignWriterCommits(["rival"], in: root)
    store.upsert(meeting("refused"))
    #expect(store.writeConflict != nil)

    // The store re-reads the library and tries again. A conflict is a transient race, not a
    // terminal state — nothing here is read-only, so the next save must be able to succeed.
    store.reloadForConflictRecovery()
    store.upsert(meeting("accepted"))

    #expect(store.writeConflict == nil, "the conflict report outlived the conflict")
    #expect(!store.unsavedChanges)
    #expect(store.storageErrorMessage == nil)
    #expect(store.meetings.contains { $0.title == "accepted" })
}

@Test("The writer lease is published as an advisory and never sets health (F190)")
@MainActor
func theWriterLeaseIsAdvisoryOnly() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = MeetingStore(rootDirectory: root)
    #expect(first.writerLease == .held(realm: "shared"))
    #expect(first.health == .complete)

    // A second store over the same root shares ONE lease rather than contending with the first.
    // `flock` attaches to the open file description, so two independent acquisitions in one process
    // would have the two stores reporting each other as rival applications.
    let second = MeetingStore(rootDirectory: root)
    #expect(second.writerLease == .held(realm: "shared"))
    #expect(second.health == .complete)
    #expect(!second.isDegraded, "the lease made a library read-only, which it must never do")

    // And it still saves.
    second.upsert(meeting("written while the lease was shared"))
    #expect(second.storageErrorMessage == nil)
}

@Test("A save failure's message is not erased by the operation that follows it (F190)")
@MainActor
func aSaveFailureMessageSurvivesTheNextStep() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base"))
    let store = MeetingStore(rootDirectory: root)
    try foreignWriterCommits(["rival"], in: root)

    // `delete` used to end with an unconditional `storageErrorMessage = nil`, so the most
    // destructive save failure in the app cleared its own explanation on the way out.
    store.upsert(meeting("will be refused"))
    let message = try #require(store.storageErrorMessage)
    #expect(store.meetings.isEmpty == false)

    // A second refused mutation must not clear it either.
    store.upsert(meeting("also refused"))
    #expect(store.storageErrorMessage != nil, "the failure explanation was cleared")
    #expect(store.storageErrorMessage?.isEmpty == false)
    _ = message
}
