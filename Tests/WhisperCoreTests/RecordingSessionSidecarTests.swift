import Foundation
import Testing
@testable import WhisperCore

// F258 — a recording's title and markers lived only in RAM, so any abrupt end lost them.
//
// `pendingMarkers` is in-memory (`AppModel.swift:162`) and first reaches storage in the
// `stopRecording` upsert. `flushPendingWrites` on quit is only debounced transcript/notes text, and
// there is no `applicationShouldTerminate`, so ⌘Q, a crash or a shutdown while recording returns the
// audio (the raw `.f32` tracks are on disk) but not the meeting: it comes back as
// "Recovered Meeting <date>" with zero markers.
//
// Field evidence, not a hypothesis: a real 63-minute meeting in the library
// (`Recordings/0432F487-…`) has `meeting.wav` and `source-tracks.json` absent and
// `meeting-recovered.wav` present — `stop()` never completed. Wall clock 14:34:44 → 15:37 is
// 62.3 min against 63.0 min of captured audio, so there was no sleep gap: the capture ran
// continuously and the process died. Exactly this ticket's case, and its markers and title are gone.
//
// This is the on-disk half: a sidecar written beside the audio while recording, so recovery has
// something to read back. It must never be able to break recovery — a missing or corrupt sidecar
// means "no metadata", never a thrown error, because the audio matters more than the markers.

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingSessionSidecarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("A session round-trips its id, start, title and markers (F258)")
func sidecarRoundTrips() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let id = UUID()
    let started = Date(timeIntervalSince1970: 1_757_000_000)
    let session = RecordingSession(
        id: id,
        startedAt: started,
        title: "Quarterly review",
        markers: [
            RecordingMarker(offset: 12.5, label: "pricing"),
            RecordingMarker(offset: 480, label: nil)
        ]
    )
    try RecordingSessionSidecar.write(session, in: directory)

    let read = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(read.id == id)
    #expect(read.startedAt == started)
    #expect(read.title == "Quarterly review")
    #expect(read.markers.count == 2)
    #expect(read.markers.first?.label == "pricing")
    #expect(read.markers.first?.offset == 12.5)
    #expect(read.markers.last?.offset == 480)
}

@Test("A directory with no sidecar reads as nil, not an error (F258)")
func missingSidecarReadsNil() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(RecordingSessionSidecar.read(in: directory) == nil)
}

@Test("A corrupt sidecar reads as nil and never throws into recovery (F258)")
func corruptSidecarReadsNil() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A truncated write is the realistic shape: the process died mid-append.
    try Data("{\"id\":\"not-a-uu".utf8)
        .write(to: directory.appendingPathComponent(RecordingSessionSidecar.filename))

    // Must be nil rather than a throw: `performStartupRecovery` rebuilds the AUDIO, and a broken
    // metadata file must never be able to stop that. Losing markers is survivable; losing the
    // meeting is not.
    #expect(RecordingSessionSidecar.read(in: directory) == nil)
}

@Test("Re-writing the sidecar replaces it rather than appending (F258)")
func sidecarWriteIsReplacing() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let started = Date(timeIntervalSince1970: 1_757_000_000)

    try RecordingSessionSidecar.write(
        RecordingSession(id: id, startedAt: started, title: "", markers: []), in: directory)
    try RecordingSessionSidecar.write(
        RecordingSession(id: id, startedAt: started, title: "Renamed",
                         markers: [RecordingMarker(offset: 1)]), in: directory)

    let read = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(read.title == "Renamed")
    #expect(read.markers.count == 1)
}

@Test("Markers accumulate in offset order across writes (F258)")
func markersStayOrdered() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let started = Date(timeIntervalSince1970: 1_757_000_000)

    // Mirrors the live path: `RecordingMarkers.inserting` sorts, and each drop rewrites the sidecar.
    var markers: [RecordingMarker] = []
    for offset in [30.0, 5.0, 12.0] {
        markers = RecordingMarkers.inserting(RecordingMarker(offset: offset), into: markers)
        try RecordingSessionSidecar.write(
            RecordingSession(id: id, startedAt: started, title: "m", markers: markers),
            in: directory)
    }

    let read = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(read.markers.map(\.offset) == [5.0, 12.0, 30.0])
}

@Test("An empty title round-trips as empty, not as a missing field (F258)")
func emptyTitleRoundTrips() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try RecordingSessionSidecar.write(
        RecordingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1), title: "",
                         markers: []),
        in: directory)
    let read = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(read.title.isEmpty)
    #expect(read.markers.isEmpty)
}

@Test("The sidecar filename is distinct from every finalization artifact (F258)")
func sidecarFilenameIsDistinct() {
    // It must not collide with what `finalizedRecording(in:)` and the rebuild look for, or a
    // metadata file could be mistaken for audio — or worse, be treated as evidence the capture
    // finished. `InterruptedRecordingRecovery` keys on meeting.wav / meeting-recovered.wav /
    // recording.<ext> / the two .f32 tracks / source-tracks*.json.
    let reserved = ["meeting.wav", "meeting-recovered.wav", "system-audio.f32",
                    "microphone-audio.f32", "source-tracks.json",
                    "source-tracks.recovered.json", "notes.md"]
    #expect(!reserved.contains(RecordingSessionSidecar.filename))
    #expect(RecordingSessionSidecar.filename.hasSuffix(".json"))
}
