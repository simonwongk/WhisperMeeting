import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F256 — a truncated recovery must still say so after the startup alert is dismissed.
//
// The startup notice is transient: `startupRecoveryMessages` is drained into one alert and gone.
// Everything else about a recovered meeting is persisted, so a warning that lives only in that
// alert is the one piece of the story the user cannot get back — which matters most here, because
// the audio is SHORT and nothing in the UI would otherwise say so.
//
// Optional added field, the append-only pattern already used for `markers`, `pinned`, `notes`,
// `tags`, `healthReport` and `alignmentWarning`: an older build ignores the key on read, and this
// build decodes its absence as nil. An older build that then SAVES the record drops the key, which
// is true of every optional field in this struct and is why none of them may be load-bearing.

@Test("A recovery warning survives a store reopen")
@MainActor
func recoveryWarningPersists() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryWarning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(
        id: id,
        title: "Recovered Meeting",
        status: .recorded,
        recoveryWarning: "Rebuilt audio stops at 12:30 because the source track could not be read past that point."
    ))
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: id)?.recoveryWarning?.contains("12:30") == true)
}

@Test("A record written without the field decodes with nil")
func olderRecordDecodesWithNilWarning() throws {
    // Forward direction: an index written before this field existed must still load. A
    // non-optional field here would make every pre-existing meeting fail to decode, and the next
    // persist would overwrite both the index and its backup.
    let fixture = #"""
    {"id":"3E3269A2-4E5B-4B0A-9A2E-444444444444","title":"Old","createdAt":700000000,
     "duration":0,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}
    """#
    let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(fixture.utf8))
    #expect(record.recoveryWarning == nil)
    #expect(record.title == "Old")
}

@Test("A clean recovery carries no warning")
@MainActor
func cleanRecoveryHasNoWarning() throws {
    // Its presence must mean exactly one thing: this audio is short by an unknown amount. Nothing
    // else may borrow the field for an unrelated notice.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryNoWarning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Fine", status: .completed))
    #expect(store.meeting(id: id)?.recoveryWarning == nil)
}

// MARK: - F281: the warning reaches the notes.md mirror

@Test("A truncated meeting's notes.md says the audio is short")
@MainActor
func recoveryWarningReachesTheSidecar() throws {
    // `notes.md` exists so the text survives an index loss (F198), which makes it the copy most
    // likely to be read with no app around it to supply context. A transcript that stops early
    // with no explanation reads as complete.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarCaveats-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    let record = MeetingRecord(
        title: "Pricing sync",
        duration: 750,
        recordingPath: "Recordings/\(folder.lastPathComponent)/meeting-recovered.wav",
        status: .completed,
        transcriptText: "We agreed on the tiering.",
        alignmentWarning: "Timestamp alignment was unavailable.",
        recoveryWarning: "The rebuilt audio stops at 12:30 because a source track could not be read past that point.",
        languageWarning: "This transcript looks like Chinese, but English was selected."
    )
    store.upsert(record)
    store.flushPendingNotesSidecars()

    let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
    #expect(notes.contains("## About this recording"))
    #expect(notes.contains("stops at 12:30"))
    // All three, not just the one this ticket was filed about — they have the same shape and the
    // same argument, and shipping one alone is the inconsistency F281 named.
    #expect(notes.contains("Timestamp alignment was unavailable."))
    #expect(notes.contains("English was selected"))
    // Severity order: only the recovery warning says content is missing.
    let caveat = try #require(notes.range(of: "stops at 12:30"))
    let alignment = try #require(notes.range(of: "Timestamp alignment"))
    let transcript = try #require(notes.range(of: "## Transcript"))
    #expect(caveat.lowerBound < alignment.lowerBound)
    #expect(alignment.lowerBound < transcript.lowerBound)
}

@Test("A clean meeting's notes.md has no caveats section")
@MainActor
func cleanMeetingSidecarHasNoCaveats() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarClean-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(
        title: "Clean",
        duration: 600,
        recordingPath: "Recordings/\(folder.lastPathComponent)/meeting.wav",
        status: .completed,
        transcriptText: "All good."
    ))
    store.flushPendingNotesSidecars()

    let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
    #expect(!notes.contains("About this recording"))
    #expect(notes.contains("All good."))
}
