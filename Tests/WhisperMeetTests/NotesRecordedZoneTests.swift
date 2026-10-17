import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F786 — since F568, notes.md showed a meeting's date in the Mac's CURRENT zone, with its offset. After
// travel the launch backfill rewrote every sidecar once with the new zone's wall-clock time: honest,
// but not the time the participants saw. `MeetingRecord.createdTimeZone` keeps the zone the meeting
// was made in, and the composition reads it. Persisted-schema rules (AGENTS.md, F188): optional,
// append-only, fixtures in both directions, and an identifier this build does not know is kept.

private let created = ISO8601DateFormatter().date(from: "2026-09-23T23:30:00Z")!

private func meeting(zone: String?, recordingPath: String = "Recordings/x/meeting.wav") -> MeetingRecord {
    MeetingRecord(
        id: UUID(), title: "Planning sync", createdAt: created, recordingPath: recordingPath,
        status: .completed, transcriptText: "hello world", createdTimeZone: zone
    )
}

private func zone(_ identifier: String) throws -> TimeZone {
    try #require(TimeZone(identifier: identifier))
}

@Test("A meeting made in Shanghai shows Shanghai's time in notes.md whichever zone the Mac is in now (F786)")
func notesShowTheRecordedZone() throws {
    let record = meeting(zone: "Asia/Shanghai")
    let inNewYork = MeetingStore.composeNotes(for: record, timeZone: try zone("America/New_York"))
    let inLondon = MeetingStore.composeNotes(for: record, timeZone: try zone("Europe/London"))
    #expect(inNewYork.contains("_2026-09-24 07:30 +08:00"), "got \(inNewYork.prefix(200))")
    #expect(inNewYork == inLondon, "a trip must not change the file")
}

@Test("A meeting with no recorded zone, or one this Mac does not know, keeps F568's current-zone date (F786)")
func notesWithoutAKnownZoneUseTheCurrentZone() throws {
    let newYork = try zone("America/New_York")
    for record in [meeting(zone: nil), meeting(zone: "Mars/Olympus_Mons")] {
        #expect(record.recordedTimeZone == nil)
        #expect(MeetingStore.composeNotes(for: record, timeZone: newYork).contains("_2026-09-23 19:30 -04:00"))
    }
}

@Test("A sidecar written for a meeting with a recorded zone is not rewritten after a time-zone change (F786)")
func aZoneChangeDoesNotRewriteTheSidecar() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F786-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings/x"), withIntermediateDirectories: true)
    let newYork = try zone("America/New_York")
    let shanghai = try zone("Asia/Shanghai")

    let recorded = meeting(zone: "Asia/Shanghai")
    #expect(MeetingStore.writeSidecarIfStale(for: recorded, root: root, timeZone: newYork))
    #expect(!MeetingStore.writeSidecarIfStale(for: recorded, root: root, timeZone: shanghai),
            "the launch backfill would rewrite every notes.md after a trip")

    // The control: without a recorded zone the file follows the Mac, as F568 made it.
    let unrecorded = meeting(zone: nil)
    #expect(MeetingStore.writeSidecarIfStale(for: unrecorded, root: root, timeZone: newYork))
    #expect(MeetingStore.writeSidecarIfStale(for: unrecorded, root: root, timeZone: shanghai))
}

// MARK: - The wire format, both directions (F188)

private func decoded(_ json: String) throws -> MeetingRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
}

private func encoded(_ record: MeetingRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(record), as: UTF8.self)
}

/// A record written by a build before F786.
private let olderRecord = #"""
{"id":"6F1A0000-0000-4000-8000-000000000786","title":"Planning",
 "createdAt":"2026-09-23T23:30:00Z","duration":1800,"recordingPath":"x/meeting.wav",
 "status":"completed","transcriptText":"hello","segments":[],"notes":""}
"""#

@Test("An index written before the field existed decodes with no recorded zone (F786)")
func anOlderIndexDecodesWithNoRecordedZone() throws {
    let record = try decoded(olderRecord)
    #expect(record.title == "Planning")
    #expect(record.createdTimeZone == nil)
    #expect(!(try encoded(record)).contains("createdTimeZone"), "nothing is invented for an old meeting")
}

@Test("A recorded zone, known or not, decodes and is written back unchanged (F786)")
func aRecordedZoneRoundTrips() throws {
    for identifier in ["Asia/Shanghai", "Mars/Olympus_Mons"] {
        let json = olderRecord.replacingOccurrences(
            of: #""notes":"""#, with: #""notes":"","createdTimeZone":"\#(identifier)""#
        )
        let record = try decoded(json)
        #expect(record.title == "Planning", "the whole record must survive, not just the field")
        #expect(record.createdTimeZone == identifier)
        let written = try encoded(record)
        #expect(written.contains(#""createdTimeZone":"\#(identifier)""#))
        #expect(try decoded(written).createdTimeZone == identifier)
    }
}

@Test("The build before F786 reads this build's index: its CodingKeys skip the new key (F786)")
func thePreviousBuildReadsTheNewKey() throws {
    // Modelled from this side, as F471 did: a key a build does not list is skipped by `Codable`, so
    // the build before this one reads an index carrying `createdTimeZone` and drops it on its next
    // save — and nothing else. A key this build does not know stands in for it here.
    let record = try decoded(olderRecord.replacingOccurrences(
        of: #""notes":"""#, with: #""notes":"","createdTimeZone":"Asia/Shanghai","aKeyFromAFutureBuild":{"x":[1]}"#
    ))
    #expect(record.title == "Planning")
    #expect(record.createdTimeZone == "Asia/Shanghai")
}

// MARK: - Reachability: the live creation paths stamp the zone

@MainActor
@Test("A recording stopped normally keeps the zone the Mac was in (F786)")
func aStoppedRecordingKeepsItsZone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F786-stop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder,
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    model.crashReportsSince = { _ in [] }
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 100.0, microphoneStart: 100.0)
    _ = await model.stopRecording(title: "Board call")

    let stored = try #require(model.store.meeting(id: id), "fixture: Stop did not index the meeting")
    // Asked of the code, not a literal: whatever zone this host is in is the one to keep.
    #expect(stored.createdTimeZone == TimeZone.current.identifier)
    #expect(stored.recordedTimeZone != nil)
}

@MainActor
@Test("An imported file keeps the zone the Mac was in when it was imported (F786)")
func anImportKeepsItsZone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F786-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    let id = UUID()
    let folder = model.store.recordingDirectoryURL(for: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("meeting.wav")
    try Data([0]).write(to: file)

    await model.adoptImportedRecording(id: id, at: file, title: "Imported", knownDuration: 1)

    let stored = try #require(model.store.meeting(id: id))
    #expect(stored.createdTimeZone == TimeZone.current.identifier)
}
