import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F642 — F433 wired `beginConflictRecovery()` (reload, and offer the losing edit back) into the
// debounced transcript/notes path and into Keep's own re-save, and nowhere else. Every other
// mutator saves synchronously: `upsert` (a new or replaced meeting — the end of every recording),
// `update` (rename, and `setTags` through it), the batch `addTag`/`removeTag`, `togglePin`, and
// `delete(ids:)`. A lost race there set `writeConflict` and the generic alert, never re-read the
// library, and left `meetingsToken` stale — so every later save in that session failed the same
// compare-and-swap, the very symptom F433's root cause names, until a relaunch.
//
// One test per mutator class, each over two real `BackupJSONStore` writers on one temp root: this
// session's store, and a rival committing through the same files (the `foreignWriterCommits` shape
// F433's tests use). Each asserts both halves of the fix: the lost edit is offered back (or, for a
// delete, nothing is offered and the user is told; or, for a new meeting, it is saved onto the
// reloaded library at once — F667), and the session can save again afterwards.
// The tests use only surface that predates this fix, so they run — and fail — against it.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyncMutatorRace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(_ title: String, id: UUID = UUID()) -> MeetingRecord {
    MeetingRecord(id: id, title: title, recordingPath: "none", status: .recorded)
}

/// Another copy of the app committing `records` over the same files, having read what is there.
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

/// A library holding one meeting, a session that has read it, and a rival that has since committed
/// its own change to that same meeting — so the session's next save loses the race.
@MainActor
private func sessionThatWillLoseARace(_ label: String) throws -> (MeetingStore, URL, UUID) {
    let root = try makeRoot()
    let id = UUID()
    MeetingStore(rootDirectory: root).upsert(meeting("Standup", id: id))
    let store = MeetingStore(rootDirectory: root)
    try foreignWriterCommits([meeting("Standup, retitled by the other copy", id: id)], in: root)
    return (store, root, id)
}

/// What every non-delete class must show after its lost race: the edit is offered back, keeping
/// it saves it against the reloaded generation, and the session can save again.
@MainActor
private func expectOfferedAndRecoverable(
    _ store: MeetingStore, root: URL, id: UUID,
    edited: (MeetingRecord) -> Bool, _ label: String
) throws {
    let offer = try #require(store.conflictOffer, "\(label): the lost edit was not offered back")
    #expect(offer.delta.contains { $0.id == id && edited($0) }, "\(label): the offer lost the edit")
    #expect(store.writeConflict == nil, "\(label): the raw conflict should have become the offer")

    store.keepConflictedEdit()

    #expect(store.conflictOffer == nil)
    #expect(store.writeConflict == nil, "\(label): keeping the edit lost the race again — the token is still stale")
    let reopened = try #require(MeetingStore(rootDirectory: root).meeting(id: id))
    #expect(edited(reopened), "\(label): the kept edit did not reach disk")

    // And the session keeps saving.
    store.upsert(meeting("Saved after the race"))
    #expect(store.writeConflict == nil, "\(label): the next save failed the same compare-and-swap")
    #expect(MeetingStore(rootDirectory: root).meetings.contains { $0.title == "Saved after the race" })
}

/// The end of every recording is an `upsert` of a meeting nobody else has. F642 offered it back like
/// an edit, which hid it until the banner was answered and let "Use the Other Copy" drop it. Since
/// F667 it is put onto the reloaded library and saved at once: the other copy has no version of it to
/// prefer, so there is nothing to ask.
@Test("A lost upsert of a new meeting is saved onto the reloaded library without asking, and the session can save again (F642, F667)")
@MainActor
func lostUpsertOfANewMeetingIsSavedAtOnce() throws {
    let (store, root, id) = try sessionThatWillLoseARace("upsert")
    defer { try? FileManager.default.removeItem(at: root) }
    let recorded = UUID()

    store.upsert(meeting("Just recorded", id: recorded))

    #expect(store.conflictOffer == nil, "a meeting only this window has was offered as a question")
    #expect(store.writeConflict == nil, "the raw conflict was left behind")
    #expect(store.meeting(id: id)?.title == "Standup, retitled by the other copy", "the library was not re-read")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: recorded)?.title == "Just recorded", "the new meeting did not reach disk")
    #expect(reopened.meeting(id: id)?.title == "Standup, retitled by the other copy", "the other copy's commit was overwritten")

    store.upsert(meeting("Saved after the race"))
    #expect(store.writeConflict == nil, "the next save failed the same compare-and-swap")
    #expect(MeetingStore(rootDirectory: root).meetings.contains { $0.title == "Saved after the race" })
}

@Test("A lost rename is offered back and the session can save again (F642)")
@MainActor
func lostRenameIsOfferedBack() throws {
    let (store, root, id) = try sessionThatWillLoseARace("update")
    defer { try? FileManager.default.removeItem(at: root) }

    store.update(id: id) { $0.title = "Renamed here" }

    try expectOfferedAndRecoverable(store, root: root, id: id,
                                    edited: { $0.title == "Renamed here" }, "update")
}

@Test("A lost tag change is offered back and the session can save again (F642)", arguments: ["setTags", "addTag", "removeTag"])
@MainActor
func lostTagChangeIsOfferedBack(mutator: String) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    var tagged = meeting("Standup", id: id)
    tagged.tags = ["weekly"]
    MeetingStore(rootDirectory: root).upsert(tagged)
    let store = MeetingStore(rootDirectory: root)
    var theirs = tagged
    theirs.title = "Standup, retitled by the other copy"
    try foreignWriterCommits([theirs], in: root)

    let expected: [String]?
    switch mutator {
    case "setTags":
        store.setTags(id: id, ["weekly", "planning"])
        expected = ["weekly", "planning"]
    case "addTag":
        store.addTag("planning", to: [id])
        expected = ["weekly", "planning"]
    default:
        store.removeTag("weekly", from: [id])
        expected = nil
    }

    try expectOfferedAndRecoverable(store, root: root, id: id,
                                    edited: { $0.tags == expected }, mutator)
}

@Test("A lost pin is offered back and the session can save again (F642)")
@MainActor
func lostPinIsOfferedBack() throws {
    let (store, root, id) = try sessionThatWillLoseARace("pin")
    defer { try? FileManager.default.removeItem(at: root) }

    store.togglePin(id: id)

    try expectOfferedAndRecoverable(store, root: root, id: id,
                                    edited: { $0.pinned == true }, "togglePin")
}

/// A delete that lost has nothing to offer back — offering to "keep" a deletion over another copy's
/// commit is a destructive choice to put one click away. So nothing is offered, the library is
/// re-read, the user is told the delete did not happen, and deleting again works.
@Test("A lost delete deletes nothing, offers nothing, says so, and a second delete works (F642)")
@MainActor
func lostDeleteReloadsAndSaysSo() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = folder.appendingPathComponent("meeting.wav")
    try Data("RIFF".utf8).write(to: audio)
    var record = meeting("Standup", id: id)
    record.recordingPath = "Recordings/\(id.uuidString)/meeting.wav"
    MeetingStore(rootDirectory: root).upsert(record)
    let store = MeetingStore(rootDirectory: root)
    var theirs = record
    theirs.title = "Standup, retitled by the other copy"
    try foreignWriterCommits([theirs], in: root)

    #expect(store.delete(ids: [id]).isEmpty, "a delete that lost the race reported itself as done")

    #expect(FileManager.default.fileExists(atPath: audio.path), "audio went with an index that was never saved")
    #expect(store.conflictOffer == nil, "a lost delete must not be offered back as a one-click redo")
    #expect(store.meeting(id: id)?.title == "Standup, retitled by the other copy",
            "the library was not re-read after the lost delete")
    let message = try #require(store.storageErrorMessage, "the user was not told the delete did not happen")
    #expect(message.contains("not deleted"), "\(message)")

    // The session is not stuck: deleting again, now against the generation it just read, works.
    store.clearStorageError()
    #expect(store.delete(ids: [id]) == [id], "the second delete failed the same compare-and-swap")
    #expect(store.writeConflict == nil)
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) == nil)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
}

/// An index can hold one id twice — a hand edit, or a merge by something other than this app. The
/// first cut of F642 keyed this session's last save by id, keeping the first copy, so the second
/// copy always "differed from what was saved" and was offered as this session's edit; Keep then
/// wrote it over its twin, and one body was gone from the index though nobody had touched either.
/// (Found by lane C's first independent review, probe P1.)
@Test("An untouched duplicate id is not offered as an edit, and Keep leaves both copies (F642)")
@MainActor
func duplicateIDsAreNotOfferedAsEdits() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dup = UUID(), other = UUID()
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let twinA = MeetingRecord(id: dup, title: "Dup A", createdAt: older.addingTimeInterval(100_000), status: .completed)
    let twinB = MeetingRecord(id: dup, title: "Dup B", createdAt: older, status: .completed)
    let x = MeetingRecord(id: other, title: "X", createdAt: older.addingTimeInterval(-10), status: .completed)
    try foreignWriterCommits([twinA, twinB, x], in: root)
    let store = MeetingStore(rootDirectory: root)
    try #require(store.meetings.filter { $0.id == dup }.count == 2)
    var theirs = x
    theirs.title = "X, retitled by the other copy"
    try foreignWriterCommits([twinA, twinB, theirs], in: root)

    store.update(id: other) { $0.title = "X renamed here" }

    let offer = try #require(store.conflictOffer)
    #expect(offer.delta.map(\.id) == [other], "an untouched duplicate was offered as this session's edit: \(offer.delta.map(\.title))")
    store.keepConflictedEdit()
    let onDisk = MeetingStore(rootDirectory: root).meetings.filter { $0.id == dup }.map(\.title).sorted()
    let expected: [String] = ["Dup A", "Dup B"]
    #expect(onDisk == expected, "Keep overwrote one duplicate with its twin")
}

/// Both copies of a duplicated id edited — the batch bar's `addTag` edits every copy of an id — and
/// the save lost. Keep used to write each offered record into the FIRST copy of its id, so both
/// edits landed in one slot and one twin's body left the index (lane C review round 2, probe P1).
@Test("When both copies of a duplicated id were edited, Keep writes each into its own slot and loses neither body (F642)")
@MainActor
func bothEditedTwinsKeepTheirOwnBodies() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dup = UUID(), other = UUID()
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let twinA = MeetingRecord(id: dup, title: "Dup A", createdAt: older.addingTimeInterval(100_000), status: .completed)
    let twinB = MeetingRecord(id: dup, title: "Dup B", createdAt: older, status: .completed)
    let x = MeetingRecord(id: other, title: "X", createdAt: older.addingTimeInterval(-10), status: .completed)
    try foreignWriterCommits([twinA, twinB, x], in: root)
    let store = MeetingStore(rootDirectory: root)
    try #require(store.meetings.filter { $0.id == dup }.count == 2)
    var theirs = x
    theirs.title = "X, retitled by the other copy"
    try foreignWriterCommits([twinA, twinB, theirs], in: root)

    store.addTag("urgent", to: [dup])
    try #require(store.conflictOffer?.delta.count == 2)
    store.keepConflictedEdit()

    let onDisk = MeetingStore(rootDirectory: root).meetings.filter { $0.id == dup }
    let titles: [String] = onDisk.map(\.title).sorted()
    #expect(titles == ["Dup A", "Dup B"], "Keep overwrote one twin with the other")
    #expect(onDisk.allSatisfy { $0.tags == ["urgent"] }, "Keep lost the tag on one twin")
}

/// Keep stamps this build's schema version on what it writes (F188, "Mark it") — and only that.
/// It used to stamp every copy of an offered id, so an untouched twin claimed a version its content
/// was never written under: the wrong marker F188's doc calls worse than none.
@Test("Keep marks only the copies it wrote, never an untouched twin (F642, F188)")
@MainActor
func keepStampsOnlyWhatItWrote() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dup = UUID(), other = UUID()
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let twinA = MeetingRecord(id: dup, title: "Dup A", createdAt: older.addingTimeInterval(100_000), status: .completed)
    var twinB = MeetingRecord(id: dup, title: "Dup B", createdAt: older, status: .completed)
    twinB.schemaVersion = nil   // written before the marker existed
    let x = MeetingRecord(id: other, title: "X", createdAt: older.addingTimeInterval(-10), status: .completed)
    try foreignWriterCommits([twinA, twinB, x], in: root)
    let store = MeetingStore(rootDirectory: root)
    var theirs = x
    theirs.title = "X, retitled by the other copy"
    try foreignWriterCommits([twinA, twinB, theirs], in: root)

    store.update(id: dup) { $0.title = "Dup A, renamed here" }   // the first copy, as `update` does
    try #require(store.conflictOffer != nil)
    store.keepConflictedEdit()

    let onDisk = MeetingStore(rootDirectory: root).meetings.filter { $0.id == dup }
    #expect(onDisk.first { $0.title == "Dup A, renamed here" } != nil)
    let untouched = try #require(onDisk.first { $0.title == "Dup B" }, "the untouched twin's body was lost")
    #expect(untouched.schemaVersion == nil, "Keep stamped a twin it never wrote")
}

/// `delete(ids:)` saves twice when a folder cannot be removed: once without the row, then again to
/// put it back (F146). Another copy saving between the two used to leave the row unlisted, the
/// token stale and the session stuck. The row is this session's to put back: F642 offered it, and
/// since F667 — the other copy's commit has no version of it, so there is nothing to choose — it is
/// listed again and saved at once, and the alert says why its folder is still there.
@Test("A delete whose folder could not be removed, and whose save putting it back lost a race, lists the row again (F642, F667)")
@MainActor
func lostRestoringSaveListsTheKeptRowAgain() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var record = meeting("Stubborn", id: id)
    record.recordingPath = "Recordings/\(id.uuidString)/meeting.wav"
    let store = MeetingStore(rootDirectory: root)
    store.upsert(record)
    let theirs = meeting("The other copy's meeting")
    // Another copy commits after this session's first save, and then the folder refuses to go.
    store.removeRecordingDirectory = { _ in
        let rival = BackupJSONStore<[MeetingRecord]>(
            primaryURL: root.appendingPathComponent("meetings.json"),
            backupURL: root.appendingPathComponent("meetings.backup.json"),
            writer: "ffff9999",
            recordCount: { $0.count }
        )
        let seen = try rival.load()
        _ = try rival.save((seen?.value ?? []) + [theirs], expecting: seen?.token)
        throw CocoaError(.fileWriteNoPermission)
    }

    #expect(store.delete(ids: [id]).isEmpty)

    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(store.conflictOffer == nil, "a row only this window has was offered as a question")
    #expect(store.writeConflict == nil, "the session was left on a stale token")
    #expect(store.meeting(id: id) != nil, "the row whose folder is still there was left unlisted")
    let message = try #require(store.storageErrorMessage, "nothing said why the meeting is still there")
    #expect(message.contains("could not have their recordings removed"), "\(message)")
    // The store's report says "these changes were not applied"; the row was, and the alert says so.
    #expect(message.contains("“Stubborn” is in your list again."), "\(message)")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: id) != nil, "the row was not saved again")
    #expect(reopened.meeting(id: theirs.id) != nil, "the other copy's commit was overwritten")
}

/// The delete's own save carries every unsaved in-memory edit with it, so a lost delete can take a
/// pending notes edit down with it. That edit is the session's own work, and it is offered back as
/// F433 offers any other; only the deletion itself is not.
@Test("A lost delete still offers back an unsaved notes edit that rode along with it (F642)")
@MainActor
func lostDeleteOffersBackAPendingEdit() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let doomed = UUID(), noted = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("To delete", id: doomed))
    seed.upsert(meeting("To note", id: noted))
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits([meeting("To delete", id: doomed), meeting("To note, retitled", id: noted)], in: root)

    store.editNotes(id: noted, text: "a note typed just before the delete")
    #expect(store.delete(ids: [doomed]).isEmpty)

    let offer = try #require(store.conflictOffer, "the pending notes edit was dropped with the lost delete")
    #expect(offer.delta.map(\.id) == [noted])
    #expect(offer.delta.first?.notes == "a note typed just before the delete")
    #expect(!offer.delta.contains { $0.id == doomed }, "the deletion itself must not be offered")
    #expect(offer.message.contains("not deleted"), "the banner must say the delete did not happen: \(offer.message)")
    #expect(store.meeting(id: doomed) != nil)
}
