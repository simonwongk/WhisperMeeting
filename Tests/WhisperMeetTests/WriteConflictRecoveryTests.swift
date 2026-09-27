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
// F433 first follow-up (a code review of the first cut) — three findings: (1) `keepConflictedEdit()`
// restored the WHOLE pre-race snapshot, silently erasing any record the reload found that was not in
// it; (2) nothing cleared a stale offer when a restore or rebuild replaced the library underneath it;
// (3) reapplying a kept edit that itself lost a NEW race finished silently instead of re-offering. A
// fourth change (F619) refuses a brand-new edit while an offer is outstanding, so there is no second
// race to lose in the first place.
//
// F433 second follow-up (a second review, tracing the delta design from the first follow-up) — three
// MORE findings, all from the same root cause: the delta was computed as "the losing snapshot diffed
// against the RIVAL's commit", which is the wrong definition of "the user's edit". (1) A record the
// rival deleted, that this session had NOT touched, still differed from the (now id-less) winner, so
// it was offered and `keepConflictedEdit()` resurrected it — a ghost meeting whose folder the rival
// may already have removed. (2) A record only the RIVAL changed — this session never touched it —
// also differed from the winner and so was ALSO offered, and Keep reapplied this session's STALE
// copy over the rival's legitimately newer one. (3) The reapply loop persisted one record at a time
// and returned on the first failure, so records after it in the loop silently never got applied and
// vanished from the re-offer. The fix: `ConflictOffer.delta` is now diffed against
// `lastPersistedMeetings` — this session's OWN last successful save — never against the rival, so it
// is exactly "what this session created or modified since it last saved", nothing more and nothing
// less; a delta record whose id the rival's commit no longer has goes to `deletedByOther` and is
// never reapplied, named in the offer's message instead; and `keepConflictedEdit()` applies the whole
// batch to `meetings` in memory and persists it ONCE, so a race on that save re-offers every record
// in the batch together.
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

/// A rival writer over the same files, committing a full F190 generation from plain titles (each a
/// brand-new id) — an entirely unrelated generation, the shape that now means "everything this
/// session had is gone as far as the rival's commit is concerned".
@MainActor
private func foreignWriterCommits(_ titles: [String], in root: URL) throws {
    try foreignWriterCommits(titles.map { meeting($0) }, in: root)
}

/// A rival writer committing an explicit set of records, preserving whatever ids the caller gives
/// them — the shape a real race usually is: the rival's copy independently touching (or deliberately
/// omitting) the SAME meetings this session already knows about.
@MainActor
private func foreignWriterCommits(_ records: [MeetingRecord], in root: URL) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let existing = try rival.load()
    _ = try rival.save(records, expecting: existing?.token)
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
    // The rival independently commits its OWN change to the SAME meeting, preserving its id — the
    // ordinary shape of a real race. (An unrelated generation that happens to lack the id entirely
    // now means "deleted by the other copy" — see `keepingConflictedEditSkipsARecordDeletedByTheOtherCopy`.)
    try foreignWriterCommits([meeting("base, rival's title", id: id)], in: root)

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
    #expect(offer.deletedByOther.isEmpty, "the rival's commit still has this id — nothing was deleted")
    // The reload adopted the rival's own value for the same id — not our edit, and not gone either.
    #expect(store.meeting(id: id)?.title == "base, rival's title")

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
    try foreignWriterCommits([meeting("base, rival's title", id: id)], in: root)
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

@Test("A record only the rival changed is excluded from the delta and keeps the rival's value after Keep (F433 second follow-up)")
@MainActor
func recordOnlyTheRivalChangedIsNotInTheDeltaAndSurvivesKeep() throws {
    // The second review finding this fixes: the first follow-up's delta was "losing snapshot diffed
    // against the winner", so a record this session never touched — but that the rival's commit
    // legitimately changed — differed from the winner just as much as this session's own edit did,
    // and `keepConflictedEdit()` reapplied this session's STALE copy over the rival's newer one.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let editedID = UUID()
    let untouchedID = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("edited", id: editedID))
    seed.upsert(meeting("untouched, original", id: untouchedID))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    // The rival's commit: "edited" unchanged from what we last saw (its own race is not what this
    // test is about), and "untouched" retitled — a change this session never made or asked for, and
    // did not even know about until the reload.
    try foreignWriterCommits([
        meeting("edited", id: editedID),
        meeting("untouched, rival's title", id: untouchedID),
    ], in: root)

    store.editNotes(id: editedID, text: "my edit")
    store.flushPendingEdits()

    let offer = try #require(store.conflictOffer)
    #expect(
        Set(offer.delta.map(\.id)) == Set([editedID]),
        "a record this session never touched must not be in the delta"
    )
    #expect(offer.deletedByOther.isEmpty)

    store.keepConflictedEdit()

    #expect(store.meeting(id: editedID)?.notes == "my edit")
    #expect(
        store.meeting(id: untouchedID)?.title == "untouched, rival's title",
        "the rival's own edit to a record we never touched was overwritten by our stale copy"
    )

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: untouchedID)?.title == "untouched, rival's title", "the rival's edit did not survive on disk")
}

@Test("Keeping a conflicted edit skips a record the rival deleted, names it in the offer's message, and still re-applies the rest (F433 second follow-up)")
@MainActor
func keepingConflictedEditSkipsARecordDeletedByTheOtherCopy() throws {
    // The second review finding this fixes: a record the RIVAL deleted, that this session had also
    // edited, differed from the (now id-less) winner and so was offered — and `keepConflictedEdit()`
    // resurrected it: a ghost meeting whose recording folder the rival's delete may have already
    // removed. Deferred, never destructive: the deletion wins, and the user is told, not left
    // guessing why their edit to it silently disappeared.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let deletedID = UUID()
    let keptID = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("will be deleted", id: deletedID))
    seed.upsert(meeting("will be kept", id: keptID))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    // The rival's commit removes "will be deleted" entirely and leaves "will be kept" untouched.
    try foreignWriterCommits([meeting("will be kept", id: keptID)], in: root)

    // Both edits are pending in the SAME debounce window — editing a second meeting reschedules the
    // one flush timer, so both are attempted, and lost, together.
    store.editNotes(id: deletedID, text: "an edit the rival's deletion outraces")
    store.editNotes(id: keptID, text: "an edit that should survive")
    store.flushPendingEdits()

    let offer = try #require(store.conflictOffer)
    #expect(Set(offer.delta.map(\.id)) == Set([keptID]), "the deleted record must not be offered for reapplication")
    #expect(Set(offer.deletedByOther.map(\.id)) == Set([deletedID]))
    #expect(offer.message.contains("will be deleted"), "the banner's message must name what was deleted")

    store.keepConflictedEdit()

    #expect(store.meeting(id: keptID)?.notes == "an edit that should survive", "the surviving record's edit was not re-applied")
    #expect(store.meeting(id: deletedID) == nil, "a meeting the rival deleted was resurrected")
    #expect(store.conflictOffer == nil)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: keptID)?.notes == "an edit that should survive")
    #expect(reopened.meeting(id: deletedID) == nil, "the resurrected ghost reached disk")
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

@Test("If reapplying a kept edit itself loses a new race, every record in the batch is re-offered together (F433 second follow-up)")
@MainActor
func keepingConflictedEditReOffersTheWholeBatchOnASecondRace() throws {
    // The second review finding this fixes: the old reapply loop persisted one record at a time and
    // returned to `beginConflictRecovery()` on the FIRST failure, so any record after it in the loop
    // was never even attempted and simply vanished from the re-offer. Applying the whole batch to
    // `meetings` in memory and persisting it once means a race on that single save re-offers every
    // record in the batch together — none of them has been marked persisted, so none is missing.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstID = UUID()
    let secondID = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("first", id: firstID))
    seed.upsert(meeting("second", id: secondID))

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits([
        meeting("first, rival's title", id: firstID),
        meeting("second, rival's title", id: secondID),
    ], in: root)

    store.editNotes(id: firstID, text: "edit one")
    store.editNotes(id: secondID, text: "edit two")
    store.flushPendingEdits()

    let offer = try #require(store.conflictOffer)
    #expect(
        Set(offer.delta.map(\.id)) == Set([firstID, secondID]),
        "both records that raced together must be in the same offer"
    )

    // A second rival commits before Keep is pressed — Keep's own single persist for the whole batch
    // will lose this race.
    try foreignWriterCommits([
        meeting("first, second rival's title", id: firstID),
        meeting("second, second rival's title", id: secondID),
    ], in: root)

    store.keepConflictedEdit()

    let secondOffer = try #require(store.conflictOffer, "the second lost race was not re-offered")
    #expect(
        Set(secondOffer.delta.map(\.id)) == Set([firstID, secondID]),
        "one of the two records silently vanished from the re-offer instead of both surviving together"
    )
    #expect(secondOffer.delta.first { $0.id == firstID }?.notes == "edit one")
    #expect(secondOffer.delta.first { $0.id == secondID }?.notes == "edit two")
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
