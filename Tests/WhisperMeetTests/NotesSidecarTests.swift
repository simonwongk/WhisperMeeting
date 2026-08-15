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
