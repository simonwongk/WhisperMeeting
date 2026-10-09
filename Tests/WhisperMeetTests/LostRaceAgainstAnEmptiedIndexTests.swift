import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F909 — a lost race against another copy's EMPTIED index turned the library read-only.
//
// Every load runs the wipe check (an empty index beside finished recordings → `.suspectEmpty`), and a
// lost save's recovery re-reads the library through that same load (`beginConflictRecovery` →
// `reloadForConflictRecovery` → `loadMeetings`). A recording this window just stopped has its finished
// folder on disk before any index lists it — that is what Stop saves — so when the other copy had
// meanwhile deleted its last meeting (its index on disk is `[]`), the re-read counted this window's own
// new folder as a meeting the index had lost, and the library opened read-only, on every launch, over a
// library that had lost nothing. F864 added a way in: a fresh library's first save is now checked, so it
// reaches this recovery too. Found by the lane-V review (probes P4, P4b, P4c).
//
// The fix: during that re-read, a folder named by a meeting this window holds and has never saved is
// explained by this window — the recovery puts that meeting back and saves it — so it is not counted.
// A folder of a meeting this window HAD saved still counts, so a rival writing `[]` over saved meetings
// still makes the library read-only (the last test).

@MainActor
private func libraryRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F909-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// What Stop leaves before it saves: the meeting's folder, named by its id, holding the mixed WAV.
private func finishRecording(_ meeting: MeetingRecord, in root: URL) throws {
    let folder = root.appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent(meeting.id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: 96_000)
    wav.append(Data(count: 96_000))
    try wav.write(to: folder.appendingPathComponent("meeting.wav"))
}

/// Another copy of the app (or any other writer) reading what is on disk and committing `change` of it.
@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

@MainActor
@Test("A fresh library's first save that loses to the other copy's emptied index keeps the library writable (F909, F864)")
func lostFirstSaveAgainstAnEmptyIndexKeepsTheLibraryWritable() throws {
    let root = try libraryRoot("fresh")
    defer { try? FileManager.default.removeItem(at: root) }
    let other = MeetingStore(rootDirectory: root)
    let here = MeetingStore(rootDirectory: root)

    // The other copy records a meeting and deletes it: its index on disk is `[]`.
    let theirs = MeetingRecord(title: "Recorded and deleted in the other window", status: .recorded)
    other.upsert(theirs, as: .result)
    #expect(other.delete(ids: [theirs.id]) == [theirs.id])

    // This window's Stop: the folder is finished, then the record is saved — and loses (rule 3a).
    let ours = MeetingRecord(title: "Recorded here", status: .recorded)
    try finishRecording(ours, in: root)
    here.upsert(ours, as: .result)

    #expect(here.health == .complete, "the lost first save left the library read-only: \(here.health)")
    #expect(here.meeting(id: ours.id) != nil)
    #expect(here.conflictOffer == nil, "a meeting only this window has is not a question")
    #expect(here.writeConflict == nil)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health == .complete, "the next launch opens read-only: \(reopened.health)")
    #expect(reopened.meeting(id: ours.id) != nil, "the recording never reached the index")
}

@MainActor
@Test("A Stop that loses to the other copy deleting its last meeting keeps the library writable (F909)")
func lostSaveAgainstAnEmptiedIndexKeepsTheLibraryWritable() throws {
    let root = try libraryRoot("emptied")
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = MeetingRecord(title: "Shared meeting", status: .completed)
    MeetingStore(rootDirectory: root).upsert(shared, as: .result)
    let other = MeetingStore(rootDirectory: root)
    let here = MeetingStore(rootDirectory: root)
    try #require(here.meeting(id: shared.id) != nil)
    #expect(other.delete(ids: [shared.id]) == [shared.id])

    let ours = MeetingRecord(title: "Recorded here", status: .recorded)
    try finishRecording(ours, in: root)
    here.upsert(ours, as: .result)

    #expect(here.health == .complete, "the lost save left the library read-only: \(here.health)")
    #expect(here.meeting(id: shared.id) == nil, "the other copy's delete was undone")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health == .complete, "the next launch opens read-only: \(reopened.health)")
    #expect(reopened.meeting(id: ours.id) != nil, "the recording never reached the index")
    #expect(reopened.meeting(id: shared.id) == nil)
}

/// The banner can be holding a recording this window has not saved — its Stop lost twice — when the
/// next lost save meets the emptied index. That recording is not in the list (only in the offer), and
/// it is still this window's: its folder is explained too, and both answers' work is done at once.
@MainActor
@Test("A recording the banner is holding is not counted against an emptied index either (F909)")
func aRecordingHeldByTheBannerIsNotTakenForAWipedMeeting() throws {
    let root = try libraryRoot("held")
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = MeetingRecord(title: "Shared meeting", status: .completed)
    MeetingStore(rootDirectory: root).upsert(shared, as: .result)
    let here = MeetingStore(rootDirectory: root)

    // This window's Stop loses twice: the other copy saves before it, and again between the
    // recovery's re-read and its save of the new recording, so the banner holds the recording.
    let first = MeetingRecord(title: "Recorded here", status: .recorded)
    try finishRecording(first, in: root)
    try otherCopyCommits(in: root) { $0.map { var r = $0; r.title = "Shared meeting, renamed there"; return r } }
    var saves = 0
    here.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 { try? otherCopyCommits(in: root) { $0.map { var r = $0; r.title = "Shared meeting, again"; return r } } }
    }
    here.upsert(first, as: .result)
    here.beforeIndexSaveForTesting = nil
    let held = try #require(here.conflictOffer, "fixture: the recording's second save lost too, so the banner holds it")
    try #require(held.unsavedNew.contains { $0.id == first.id })
    try #require(here.meeting(id: first.id) == nil)

    // The other copy then deletes its last meeting, and a second recording stops here.
    try otherCopyCommits(in: root) { _ in [] }
    let second = MeetingRecord(title: "Recorded here, later", status: .recorded)
    try finishRecording(second, in: root)
    here.upsert(second, as: .result)

    #expect(here.health == .complete, "the lost save left the library read-only: \(here.health)")
    #expect(here.conflictOffer == nil, "nothing is left to ask: \(here.conflictOffer?.message ?? "")")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health == .complete, "the next launch opens read-only: \(reopened.health)")
    #expect(reopened.meeting(id: first.id) != nil, "the recording the banner held never reached the index")
    #expect(reopened.meeting(id: second.id) != nil, "the second recording never reached the index")
}

/// The narrowing must not cost the wipe check itself: a rival that writes `[]` over a meeting this
/// window HAD saved, and leaves its finished folder, is the 2026-08-14 shape, and the race's re-read
/// still finds it.
@MainActor
@Test("A lost save against an index wiped of meetings this window had saved still makes the library read-only (F909, F187)")
func aRaceAgainstAWipedIndexStillDegrades() throws {
    let root = try libraryRoot("wiped")
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = MeetingRecord(title: "Shared meeting", status: .completed)
    try finishRecording(shared, in: root)
    MeetingStore(rootDirectory: root).upsert(shared, as: .result)
    let here = MeetingStore(rootDirectory: root)
    try #require(here.meeting(id: shared.id) != nil)

    // Another writer (an old build, a bug) commits `[]` and leaves the folder alone.
    try otherCopyCommits(in: root) { _ in [] }

    here.update(id: shared.id) { $0.title = "Renamed here" }

    #expect(here.health == .suspectEmpty(recordingFolderCount: 1), "a race against a wiped index no longer degrades: \(here.health)")
    #expect(MeetingStore(rootDirectory: root).isDegraded)
}
