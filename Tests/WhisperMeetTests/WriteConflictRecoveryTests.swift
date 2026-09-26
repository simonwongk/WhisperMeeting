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
// F433 follow-up (a code review of the first cut) — three more findings, all fixed in the same
// area: (1) `keepConflictedEdit()` restored the WHOLE pre-race snapshot, silently erasing any record
// the reload found that was not in it (`ConflictOffer` now carries only the delta, reapplied one
// record at a time through the normal mutators); (2) nothing cleared a stale offer when a restore or
// rebuild replaced the library underneath it; (3) reapplying a kept edit that itself lost a NEW race
// finished silently instead of re-offering. A fourth change (F619) refuses a brand-new edit while an
// offer is outstanding, so there is no second race to lose in the first place.
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
        offer.delta.first { $0.id == id }?.notes == "my unsaved note",
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
    // The rival's own record must survive a Keep — a wholesale-snapshot Keep (the review finding
    // this follow-up fixes) would have erased it, since it never existed in the losing snapshot.
    #expect(store.meetings.contains { $0.title == "rival wins" })
    #expect(store.meetings.count == 2)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: id)?.notes == "keep me", "the kept edit did not reach disk")
    #expect(reopened.meetings.contains { $0.title == "rival wins" }, "the kept edit's save overwrote an unrelated record on disk")
}

@Test("Keeping a conflicted edit reapplies only the record that raced, never the rival's own record (F433 follow-up)")
@MainActor
func keepingConflictedEditDoesNotOverwriteUnrelatedRecords() throws {
    // The review finding this fixes, reproduced directly: the first cut's `keepConflictedEdit()`
    // did `meetings = offer.losingMeetings` — the WHOLE pre-race snapshot — so anything the winner
    // had that was not in that snapshot (here, the rival's own "rival wins" record) was silently
    // erased the moment the user pressed Keep. No second race or interleaved edit is needed to see
    // it: the rival's record is already there the moment the offer is created.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "keep me")
    store.flushPendingEdits()
    let offer = try #require(store.conflictOffer)
    #expect(offer.delta.count == 1, "only the record that actually raced belongs in the offer")
    #expect(store.meetings.contains { $0.title == "rival wins" }, "the premise: the rival's record is already present before Keep is even pressed")

    store.keepConflictedEdit()

    #expect(store.meeting(id: id)?.notes == "keep me", "the kept edit was not re-applied")
    #expect(store.meetings.contains { $0.title == "rival wins" }, "an unrelated record the rival committed was overwritten by the stale snapshot")
    #expect(store.meetings.count == 2, "both the kept edit and the rival's own record must survive")
}

@Test("A restored or rebuilt index clears any outstanding conflict offer (F433 follow-up)")
@MainActor
func restoringOrRebuildingClearsTheConflictOffer() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "unsaved")
    store.flushPendingEdits()
    #expect(store.conflictOffer != nil, "the fixture must produce an outstanding offer")

    // `installRebuiltIndex` is the second mutator that works regardless of the ordinary edit gate —
    // it must not leave a stale offer standing over the library it just replaced.
    try store.installRebuiltIndex([meeting("rebuilt")])

    #expect(store.conflictOffer == nil, "a stale conflict snapshot survived a rebuilt library")
}

@Test("If reapplying a kept edit itself loses a new race, the app re-offers rather than finishing silently (F433 follow-up)")
@MainActor
func keepingConflictedEditReOffersOnASecondRace() throws {
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

    // A second rival commits before Keep is pressed — Keep's own reapply-save will lose this race.
    try foreignWriterCommits(["second rival wins"], in: root)

    store.keepConflictedEdit()

    // Never silent: a fresh offer, not a dangling `writeConflict` with nothing left to act on.
    let secondOffer = try #require(store.conflictOffer, "the second lost race was not re-offered")
    #expect(
        secondOffer.delta.first { $0.id == id }?.notes == "keep me",
        "the edit being kept was dropped instead of re-offered"
    )
    #expect(store.meetings.contains { $0.title == "second rival wins" })
}

@Test("A new edit is refused while a conflict offer is outstanding, so there is no second race to lose or a second alert (F433 follow-up, F619)")
@MainActor
func newEditsAreRefusedWhileAnOfferIsOutstanding() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "raced edit")
    store.flushPendingEdits()
    #expect(store.conflictOffer != nil)
    let attemptsBefore = store.persistCount
    let messageBefore = store.storageErrorMessage

    // A brand-new, otherwise-unrelated edit attempted while the offer is still outstanding.
    store.upsert(meeting("should be refused", id: UUID()))

    #expect(store.persistCount == attemptsBefore, "a new edit attempted a write while the offer was outstanding")
    #expect(!store.meetings.contains { $0.title == "should be refused" }, "the refused edit was applied anyway")
    #expect(store.storageErrorMessage == messageBefore, "the refusal must not pop a second modal alert")
    #expect(store.conflictOffer != nil, "the outstanding offer must survive an unrelated refused edit")
}

@Test("The write-conflict banner is wired to its two controls and gated on the restore flag (F433)")
@MainActor
func writeConflictBannerIsReachable() throws {
    // F306's method: asserted against `ContentView`'s source with comments stripped, because the
    // `WhisperMeet` target has no view harness (F174).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("WriteConflictBanner"))
    #expect(source.contains("store.keepConflictedEdit()"))
    #expect(source.contains("store.discardConflictedEdit()"))
    #expect(source.contains("store.conflictOffer"))
    #expect(source.contains("!store.isRestoringLibrary"), "the banner must not render mid-restore")
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
