import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F479 — opening a meeting on a read-only library raised the "library is read-only" alert, though
// the user changed nothing. F313's alert-on-a-non-mutation, in a new place.
//
// The ticket named two writes the detail view made on open. The notes one is gone: F564 (5766bf5)
// replaced the `.onChange(of: notesDraft)` that wrote the seeded notes back with a binding whose
// setter only typing reaches, and `notesSeedingWritesNothing` below pins that. The other — the
// one-time upgrade of a transcript from before the unified-transcript change — was still there: it
// called `store.update` from `.onAppear`, the refusal set `storageErrorMessage`, and ContentView
// shows that as a modal. On a read-only library the upgrade can never be saved, so every open of
// such a meeting raised it again.

/// A read-only library that still holds a record: the primary index is corrupted after a writable
/// store saved it, so the reopened store loads from the backup (`.recoveredFromBackup`) — the
/// degraded state a truncated write produces in the field, and the only one with meetings to open.
@MainActor
private func makeReadOnlyLibrary(with meeting: MeetingRecord) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F479-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting)
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")
    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    let store = MeetingStore(rootDirectory: root)
    try #require(store.isDegraded, "the reopened library must be read-only")
    try #require(store.meeting(id: meeting.id) != nil, "the read-only library must still hold the meeting")
    // Precondition for every assertion on it below: nothing has been said before the meeting opens.
    try #require(store.storageErrorMessage == nil, "the library raised before anything was opened")
    return (store, root)
}

/// A meeting transcribed before the unified-transcript change: completed, with segments and a plain
/// transcript, never marked normalized.
private func preUnifiedMeeting(notes: String? = nil) -> MeetingRecord {
    let id = UUID()
    return MeetingRecord(
        id: id,
        title: "Quarterly review",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: "We shipped the release. Then we planned the next one.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 2, text: "We shipped the release."),
            TranscriptSegment(speaker: nil, start: 2, end: 4, text: "Then we planned the next one."),
        ],
        notes: notes
    )
}

@MainActor
@Test("Opening an old meeting on a read-only library raises no alert and changes nothing (F479)")
func openingAnOldMeetingReadOnlyRaisesNoAlert() throws {
    let meeting = preUnifiedMeeting()
    let (store, root) = try makeReadOnlyLibrary(with: meeting)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistsBefore = store.persistCount

    // What the detail view's `.onAppear` does.
    store.normalizeTranscriptIfNeeded(id: meeting.id)

    #expect(store.storageErrorMessage == nil, "an open raised: \(store.storageErrorMessage ?? "")")
    let loaded = try #require(store.meeting(id: meeting.id))
    #expect(loaded.transcriptText == meeting.transcriptText)
    #expect(loaded.transcriptNormalized == nil)
    #expect(store.persistCount == persistsBefore)
}

@MainActor
@Test("A writable library still upgrades an old transcript when it is opened (F479)")
func openingAnOldMeetingWritableStillNormalizes() throws {
    // The guard must not turn the upgrade into a no-op everywhere: it is skipped only where it
    // could not be saved, and runs on the next open once the library is writable again.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F479-writable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let meeting = preUnifiedMeeting()
    store.upsert(meeting)

    store.normalizeTranscriptIfNeeded(id: meeting.id)

    let loaded = try #require(store.meeting(id: meeting.id))
    #expect(loaded.transcriptNormalized == true)
    #expect(TranscriptFormatter.isTimestamped(loaded.transcriptText))
    #expect(store.storageErrorMessage == nil)
}

@MainActor
@Test("Seeding the notes field when a meeting opens writes nothing on a read-only library (F479, F564)")
func notesSeedingWritesNothing() throws {
    // The ticket's original trigger. Passes on the tree this ticket was claimed against — F564
    // closed it — and stays here so a return of a seed-then-write path is caught.
    let meeting = preUnifiedMeeting(notes: "the original notes")
    let (store, root) = try makeReadOnlyLibrary(with: meeting)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistsBefore = store.persistCount

    // What `notesSection`'s `.onAppear` does, and then the same text arriving at the binding's
    // setter, as it would if the text view echoed the seeded value back.
    var draft = SharedFieldDraft(stored: store.meeting(id: meeting.id)?.notes ?? "")
    MeetingFieldSync.typeNotes("the original notes", into: &draft, store: store, meetingID: meeting.id)

    #expect(store.storageErrorMessage == nil, "seeding raised: \(store.storageErrorMessage ?? "")")
    #expect(store.meeting(id: meeting.id)?.notes == "the original notes")
    #expect(store.persistCount == persistsBefore)
}

@MainActor
@Test("The detail view opens a meeting through the store's guarded upgrade and seeds notes without writing (F479)")
func detailViewUsesTheGuardedOpenPath() throws {
    // ContentView cannot be rendered here (F174), so its source is asserted, comments stripped.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains(".onAppear { store.normalizeTranscriptIfNeeded(id: meeting.id) }"))
    // The view keeps no copy of the upgrade that writes around the store's guard.
    #expect(!source.contains("func normalizeTranscriptIfNeeded"))
    // F564's shape: no write is driven by a change of the draft itself.
    #expect(!source.contains(".onChange(of: notesDraft)"))
}
