import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F433 — persistMeetings()'s catch branch never refreshed `meetingsToken`, and the one thing that
// re-reads the library, `reloadForConflictRecovery()`, had no production caller: it was called only
// from `MeetingStoreGenerationTests`. So once a rival wrote first, EVERY later save in that session
// failed the identical compare-and-swap, and `flushPendingEdits()`'s failure branch re-armed
// unconditionally (`if !persistMeetings() { scheduleDebouncedPersist() }`), turning one keystroke
// into a write-and-alert loop that repeated every debounce interval forever.
//
// These tests drive `MeetingStore` directly (headless), over a temp root — never a user's library.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WriteConflictRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(_ title: String, id: UUID = UUID()) -> MeetingRecord {
    MeetingRecord(id: id, title: title, recordingPath: "none", status: .recorded)
}

/// A rival writer over the same files, committing a full F190 generation — an old bundle, a second
/// app instance, or a hand-restore that went through the store. Same shape as
/// `MeetingStoreGenerationTests.foreignWriterCommits`, kept local so this file stays self-contained.
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

@Test("A lost race during a debounced flush reloads and offers the losing edit back, instead of retrying forever (F433)")
@MainActor
func lostRaceDuringDebouncedFlushOffersRatherThanRetries() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    // A large debounce so only the explicit `flushPendingEdits()` calls below write — the point of
    // this test is what happens ACROSS those calls, not the coalescing itself (that's F40/F133's).
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)

    store.editNotes(id: id, text: "my unsaved note")
    let attemptsBefore = store.persistCount

    // The debounce timer firing once, as it would in production.
    store.flushPendingEdits()

    #expect(store.persistCount == attemptsBefore + 1, "expected exactly one write attempt")
    #expect(store.writeConflict == nil, "the raw conflict should have been folded into conflictOffer")
    let offer = try #require(store.conflictOffer, "the losing edit was not retained or offered")
    #expect(
        offer.losingMeetings.first { $0.id == id }?.notes == "my unsaved note",
        "the edit that lost the race was dropped instead of kept"
    )
    // The reload replaced `meetings` with the winner — the rival's commit REPLACED the whole array
    // (a fresh generation, not a merge), so the original id is simply gone and the loser is not
    // what's shown, only what's offered.
    #expect(store.meeting(id: id) == nil, "the reload did not adopt the rival's generation")
    #expect(store.meetings.contains { $0.title == "rival wins" })

    // The retry storm: in production the debounce timer would fire again here. Nothing re-armed
    // it, so calling the same flush entry point again — exactly what the timer would have done —
    // must be a no-op rather than another doomed attempt.
    store.flushPendingEdits()
    store.flushPendingEdits()
    store.flushPendingEdits()
    #expect(
        store.persistCount == attemptsBefore + 1,
        "the flush kept retrying after a lost race instead of deferring to the user"
    )
}

@Test("Keeping the conflicted edit re-applies and saves it against the reloaded generation (F433)")
@MainActor
func keepingConflictedEditReappliesAndSaves() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "keep me")
    store.flushPendingEdits()
    #expect(store.conflictOffer != nil)

    store.keepConflictedEdit()

    #expect(store.conflictOffer == nil)
    #expect(store.meeting(id: id)?.notes == "keep me", "the kept edit was not re-applied")
    #expect(store.writeConflict == nil, "the retry against the freshly reloaded generation should succeed")

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: id)?.notes == "keep me", "the kept edit did not reach disk")
}

@Test("Discarding the conflicted edit keeps the reloaded copy and stops offering the alternative (F433)")
@MainActor
func discardingConflictedEditKeepsTheWinner() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "discard me")
    store.flushPendingEdits()
    #expect(store.conflictOffer != nil)

    store.discardConflictedEdit()

    #expect(store.conflictOffer == nil)
    #expect(store.meeting(id: id) == nil, "the original meeting should not have survived the reload")
    #expect(store.meetings.contains { $0.title == "rival wins" })
}
