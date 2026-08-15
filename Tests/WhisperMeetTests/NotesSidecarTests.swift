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
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = MeetingRecord(
        id: UUID(),
        title: "Transcript only",
        recordingPath: "",
        status: .completed,
        transcriptText: "kept text"
    )
    store.upsert(meeting)

    store.flushPendingNotesSidecars()

    #expect(store.sidecarWriteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings").path))
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
