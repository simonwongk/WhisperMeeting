import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetSidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Large debounce so tests drive flushes explicitly (the F40 pattern).
    return (MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999), root)
}

@MainActor
private func seedMeeting(in store: MeetingStore, root: URL, transcript: String = "hello world") throws -> MeetingRecord {
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    let meeting = MeetingRecord(
        id: id,
        title: "Planning sync",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: transcript
    )
    store.upsert(meeting)
    return meeting
}

@Test("The sidecar composer produces exactly what the manual export produces")
@MainActor
func notesMarkdownMatchesTheExporter() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)

    let composed = store.notesMarkdown(for: meeting)
    let direct = MeetingNotesExporter.markdown(
        title: meeting.title,
        dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
        durationSeconds: meeting.duration,
        languageCode: meeting.languageCode,
        summary: meeting.summary,
        transcriptText: meeting.transcriptText,
        notes: meeting.notes,
        markers: meeting.orderedMarkers,
        segments: meeting.segments
    )
    #expect(composed == direct)
    #expect(composed.contains("Planning sync"))
    #expect(composed.contains("hello world"))
}

@Test("A transcript edit writes notes.md beside the audio after the flush")
@MainActor
func transcriptEditWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)

    store.editTranscript(id: meeting.id, text: "corrected text")
    store.flushPendingEdits()
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    let current = try #require(store.meeting(id: meeting.id))
    #expect(written == store.notesMarkdown(for: current))
    #expect(written.contains("corrected text"))
}

// Each mutator hook is pinned individually (F198): deleting any single `scheduleNotesSidecarWrite`
// call must turn exactly one of the next three tests red. `editTranscript`'s hook is pinned by
// `transcriptEditWritesTheSidecar` above.

@Test("An upsert alone queues the sidecar — flushing right after seeding writes notes.md")
@MainActor
func upsertAloneWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seeding IS the upsert under test — no further edits before the flush (F198).
    let meeting = try seedMeeting(in: store, root: root)

    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    let current = try #require(store.meeting(id: meeting.id))
    #expect(written == store.notesMarkdown(for: current))
    #expect(store.sidecarWriteCount == 1)
}

@Test("An update(id:) alone marks the sidecar stale — a title rename lands in notes.md")
@MainActor
func updateAloneWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)
    store.flushPendingNotesSidecars()   // settle the seed's queue; only `update` may re-queue (F198)
    let before = store.sidecarWriteCount

    store.update(id: meeting.id) { $0.title = "Renamed sync" }
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    #expect(written.contains("Renamed sync"))
    #expect(store.sidecarWriteCount == before + 1)
}

@Test("A notes edit alone marks the sidecar stale — the note text lands in notes.md")
@MainActor
func notesEditAloneWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)
    store.flushPendingNotesSidecars()   // settle the seed's queue; only `editNotes` may re-queue (F198)
    let before = store.sidecarWriteCount

    store.editNotes(id: meeting.id, text: "Follow up with the vendor")
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    #expect(written.contains("Follow up with the vendor"))
    #expect(store.sidecarWriteCount == before + 1)
}

// The quit-time path (F198): `update` persists the index synchronously, so `pendingIndexFlush` is nil
// while the sidecar queue is NOT empty. `flushPendingEdits()` alone must still flush the sidecars —
// this is red if the sidecar flush hides behind the index queue's early return.
@Test("flushPendingEdits flushes queued sidecars even when no index flush is pending")
@MainActor
func flushPendingEditsAloneWritesTheSidecar() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)
    store.flushPendingNotesSidecars()

    store.update(id: meeting.id) { $0.title = "Renamed before quit" }
    store.flushPendingEdits()   // the ONLY flush — a quitting app calls nothing else (F198)

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    #expect(written.contains("Renamed before quit"))
}

// The launch wiring (F198): `performStartupRecovery` must run the sidecar backfill, so a library
// transcribed before this feature existed gains its notes.md on the next launch.
@Test("Startup recovery backfills notes.md for an already-indexed meeting")
@MainActor
func startupRecoveryBackfillsTheSidecar() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root, transcript: "pre-existing transcript")
    let suite = "F198.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.performStartupRecovery()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    let written = try String(contentsOf: sidecar, encoding: .utf8)
    let current = try #require(store.meeting(id: meeting.id))
    #expect(written == store.notesMarkdown(for: current))
}

@Test("Identical content is not rewritten — a pin toggle leaves the sidecar untouched")
@MainActor
func identicalContentIsNotRewritten() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try seedMeeting(in: store, root: root)
    store.flushPendingNotesSidecars()
    let before = store.sidecarWriteCount

    // A pin change routes through the hooked `update(id:)` here; the pin is not part of the notes
    // document, so the composed content is identical and the file must not be rewritten.
    store.update(id: meeting.id) { $0.pinned = true }
    store.flushPendingNotesSidecars()

    #expect(store.sidecarWriteCount == before)
}

@Test("A meeting whose recording folder is missing is skipped without creating anything")
@MainActor
func audioLessMeetingIsSkipped() throws {
    // A dedicated parent directory, because the empty-path case below resolves to the directory
    // ABOVE the library root — the sweep at the end must be able to prove nothing landed there (F198).
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetSidecarContainer-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999)

    // An empty `recordingPath` resolves to the library root's PARENT, which the containment check
    // rejects (F198).
    store.upsert(MeetingRecord(
        id: UUID(),
        title: "Transcript only",
        recordingPath: "",
        status: .completed,
        transcriptText: "kept text"
    ))
    // A non-empty path whose folder was never created — the folder-exists guard, distinct from
    // containment: the sidecar writer must never create a directory (F198).
    store.upsert(MeetingRecord(
        id: UUID(),
        title: "Folder gone",
        recordingPath: "Recordings/\(UUID().uuidString)/meeting.wav",
        status: .completed,
        transcriptText: "kept text"
    ))

    store.flushPendingNotesSidecars()

    #expect(store.sidecarWriteCount == 0)
    // No notes.md anywhere under the container — covering the library root, its parent, and
    // everything below them.
    let everything = FileManager.default.enumerator(at: container, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL } ?? []
    #expect(!everything.contains { $0.lastPathComponent == "notes.md" })
}

@Test("Backfill writes a sidecar for every existing meeting, and a second run writes nothing")
@MainActor
func backfillIsIdempotent() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try seedMeeting(in: store, root: root, transcript: "first meeting")
    let b = try seedMeeting(in: store, root: root, transcript: "second meeting")

    await store.backfillNotesSidecars()
    let afterFirst = store.sidecarWriteCount
    #expect(afterFirst == 2)
    for meeting in [a, b] {
        let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }
    // The backfilled file is the real composed document, not merely present (F198).
    let currentA = try #require(store.meeting(id: a.id))
    let writtenA = try String(
        contentsOf: root.appendingPathComponent("Recordings/\(a.id.uuidString)/notes.md"),
        encoding: .utf8
    )
    #expect(writtenA == store.notesMarkdown(for: currentA))

    await store.backfillNotesSidecars()
    #expect(store.sidecarWriteCount == afterFirst)
}

@Test("No sidecar is written while the library is read-only")
@MainActor
func noSidecarWhileDegraded() async throws {
    let (seedStore, root) = try makeStore()
    let meeting = try seedMeeting(in: seedStore, root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    // Corrupt only the primary; copy it to the backup first so the reopened store still holds the
    // record (`.recoveredFromBackup` — degraded AND populated).
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    try? FileManager.default.removeItem(at: backup)
    try FileManager.default.copyItem(at: primary, to: backup)
    try Data("broken-primary".utf8).write(to: primary)

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999)
    #expect(store.isDegraded)
    #expect(!store.meetings.isEmpty)

    await store.backfillNotesSidecars()
    store.flushPendingNotesSidecars()

    let sidecar = root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(store.sidecarWriteCount == 0)
}
