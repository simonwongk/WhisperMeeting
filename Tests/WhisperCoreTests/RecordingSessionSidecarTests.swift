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

// MARK: - F253: recording that a power event interrupted the capture

@Test("A sleep interruption round-trips in the sidecar (F253)")
func sidecarRecordsASleepInterruption() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The finalize on `willSleep` is best-effort — macOS allows a few seconds, and mixing a
    // 63-minute capture means reading ~1.4 GB, which will not fit. So the *fast* thing is the
    // guarantee: note that sleep interrupted this capture, in a few hundred atomic bytes, so
    // recovery can say what happened instead of showing a generic notice.
    let at = Date(timeIntervalSince1970: 1_757_000_500)
    var session = RecordingSession(
        id: UUID(), startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "", markers: []
    )
    session.interruptedBySleepAt = at
    try RecordingSessionSidecar.write(session, in: directory)

    #expect(RecordingSessionSidecar.read(in: directory)?.interruptedBySleepAt == at)
}

@Test("A sidecar written before F253 still decodes (F253)")
func preF253SidecarStillDecodes() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The field must be Optional, not required: a recording started under the previous build and
    // interrupted after an update would otherwise fail to decode and lose its markers — the exact
    // failure F188's lenient-decode rule exists to prevent, one file over.
    let json = """
    {"id":"\(UUID().uuidString)","startedAt":"2026-09-16T14:34:44Z","title":"Old","markers":[]}
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent(RecordingSessionSidecar.filename))

    let read = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(read.title == "Old")
    #expect(read.interruptedBySleepAt == nil)
}

// MARK: - F283: a capture that is mid-outage is not a dead capture

@Test("A session mid-outage reads as live, so a rival does not rebuild it (F283)")
func midOutageSessionReadsAsLive() {
    // F279 decides a folder is dead by sampling the raw tracks twice and seeing no growth. That is
    // correct for a crashed capture and wrong for one of F275's outages: a Mac asleep for four
    // minutes is not capturing, so its tracks do not grow, and F275 will resume it on wake. A rival
    // instance launching in that window would rebuild a live recording — F255 again.
    //
    // So the writer records the fact. `outageBeganAt` is set when the outage starts and cleared
    // when capture resumes, and it is written at `willSleep` — BEFORE the gap — so the fact is on
    // disk whenever the second instance happens to look. That removes the question of whether
    // `didWake` arrives before or after a rival's launch, rather than answering it by measurement.
    var session = RecordingSession(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "",
        markers: []
    )
    let began = Date(timeIntervalSince1970: 1_757_000_100)
    session.outageBeganAt = began

    #expect(session.isMidOutage(now: began.addingTimeInterval(1)))
    #expect(session.isMidOutage(now: began.addingTimeInterval(60)))
}

@Test("An outage older than the pad cap stops protecting the folder (F283)")
func staleOutageStopsProtecting() {
    // whisper-62's bound, and it is not a window in disguise: past
    // `CaptureRestartPolicy.defaultMaximumPaddedGap` the policy FINALIZES rather than resuming, so
    // a folder whose outage began longer ago than that is definitively not going to be resumed.
    // Without the bound, an app that died mid-outage would leave the flag set forever and its
    // recording would never be recovered — the defer-forever outcome F279 rejects, and strictly
    // worse than the bug being fixed.
    var session = RecordingSession(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "",
        markers: []
    )
    let began = Date(timeIntervalSince1970: 1_757_000_100)
    session.outageBeganAt = began
    let cap = CaptureRestartPolicy.defaultMaximumPaddedGap

    #expect(session.isMidOutage(now: began.addingTimeInterval(cap - 1)))
    #expect(!session.isMidOutage(now: began.addingTimeInterval(cap)))
    #expect(!session.isMidOutage(now: began.addingTimeInterval(cap + 3_600)))
}

@Test("A session with no outage recorded is not protected (F283)")
func noOutageMeansNoProtection() {
    let session = RecordingSession(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "",
        markers: []
    )
    #expect(session.outageBeganAt == nil)
    #expect(!session.isMidOutage(now: Date()))
}

@Test("A clock that moved backwards does not protect indefinitely (F283)")
func backwardsClockIsNotProtection() {
    // `outageBeganAt` in the future makes `now - began` negative, which is inside any cap. An NTP
    // correction across a sleep is the realistic cause, and the honest answer is the same as
    // F275's for a negative gap: treat it as no information rather than as unbounded protection.
    var session = RecordingSession(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "",
        markers: []
    )
    session.outageBeganAt = Date(timeIntervalSince1970: 1_757_999_999)
    #expect(!session.isMidOutage(now: Date(timeIntervalSince1970: 1_757_000_100)))
}

@Test("A session written before F283 decodes with no outage (F283)")
func olderSessionsDecodeWithoutTheField() throws {
    let json = #"""
    {"id":"7A1B0000-0000-4000-8000-000000000001","startedAt":761000000,
     "title":"Budget","markers":[]}
    """#
    let session = try JSONDecoder().decode(RecordingSession.self, from: Data(json.utf8))
    #expect(session.outageBeganAt == nil)
    #expect(!session.isMidOutage(now: Date()))
    #expect(session.title == "Budget")
}
