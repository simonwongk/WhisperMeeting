import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeDegradedStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetDegraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    return (MeetingStore(rootDirectory: root), root)
}

/// A degraded store that still holds a real record and real audio (F187).
///
/// `makeDegradedStore()` produces `.unreadable`, where `meetings` is empty — so every mutator's
/// *second* guard (`guard let meeting = meeting(id:)`) returns first and the read-only guard is never
/// the thing doing the work. `.recoveredFromBackup` is the degraded state a truncated primary write
/// actually produces in the field, and the only one carrying records and audio a mutator could destroy.
/// The seed store is `.complete` (no index files exist yet), so its `upsert` is allowed and
/// `BackupJSONStore.save` lays down identical primary and backup copies; corrupting only the primary
/// makes the reopened store load from the backup: non-empty and read-only.
@MainActor
private func makeBackupRecoveredStore() throws -> (store: MeetingStore, root: URL, meeting: MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetRecovered-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))

    let meeting = MeetingRecord(
        id: id,
        title: "Quarterly review",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        transcriptText: "the original transcript",
        notes: "the original notes"
    )
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting)
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")

    // Corrupt ONLY the primary. The backup stays valid, so `load()` returns `.recoveredFromBackup`.
    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))

    return (MeetingStore(rootDirectory: root), root, meeting)
}

@Test("An index recovered from backup keeps its records and is still read-only")
@MainActor
func backupRecoveredIndexIsPopulatedAndDegraded() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.health == .recoveredFromBackup)
    #expect(store.meetings.map(\.id) == [meeting.id])
    #expect(store.isDegraded)
}

@Test("An unreadable index leaves the store degraded rather than empty-and-writable")
@MainActor
func unreadableIndexIsDegraded() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(!store.health.allowsMutation)
}

@Test("Deleting while degraded removes no audio and no record")
@MainActor
func degradedDeleteRemovesNothing() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(id: id)

    #expect(!removalAttempted)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    #expect(store.storageErrorMessage != nil)
}

// The store's own delete guard, exercised against a record that exists — `delete` calls
// `removeRecordingDirectory` BEFORE it persists the index, so a guard placed anywhere later would
// destroy the audio and merely decline to save. The stub performs the real removal so that a missing
// guard actually costs the file on disk, not just a flag (F187).
@Test("Deleting a real meeting while degraded removes neither its audio nor its record")
@MainActor
func degradedDeleteKeepsRealAudioAndRecord() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent(meeting.recordingPath)
    try #require(FileManager.default.fileExists(atPath: audio.path))
    var removalAttempted = false
    store.removeRecordingDirectory = { url in
        removalAttempted = true
        try FileManager.default.removeItem(at: url)
    }
    let before = store.persistCount

    store.delete(id: meeting.id)

    #expect(!removalAttempted)
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(store.meetings.map(\.id) == [meeting.id])
    #expect(store.persistCount == before)
    #expect(store.storageErrorMessage != nil)
}

// The record-editing guards, against a real id so the `firstIndex(where:)` lookup succeeds and only the
// read-only guard can stop the write (F187).
@Test("Edits to a real meeting are refused while degraded")
@MainActor
func degradedEditsToRealMeetingAreRefused() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.update(id: meeting.id) { $0.title = "Renamed" }
    store.editTranscript(id: meeting.id, text: "overwritten transcript")
    store.editNotes(id: meeting.id, text: "overwritten notes")
    store.togglePin(id: meeting.id)
    store.setTags(id: meeting.id, ["x"])

    let loaded = try #require(store.meeting(id: meeting.id))
    #expect(loaded.title == meeting.title)
    #expect(loaded.transcriptText == meeting.transcriptText)
    #expect(loaded.notes == meeting.notes)
    #expect(loaded.pinned == nil)
    #expect(loaded.tags == nil)
    #expect(store.persistCount == before)
    #expect(store.storageErrorMessage != nil)
}

// `setTags` against a real id lives in `degradedEditsToRealMeetingAreRefused` — passing an unknown UUID
// here would early-return on the lookup and assert nothing about the read-only guard.
@Test("No mutation while degraded reaches disk or memory")
@MainActor
func degradedMutationsAreRefused() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.upsert(MeetingRecord(title: "New"))
    store.addVocabulary(["term"])

    #expect(store.meetings.isEmpty)
    #expect(store.vocabulary.isEmpty)
    #expect(store.persistCount == before)
}

@Test("A degraded index reports no orphans, so startup cannot rebuild over it")
@MainActor
func degradedIndexReportsNoOrphans() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(try store.orphanedRecordings().isEmpty)
}

// A recording started while the library is read-only produces audio the store then refuses to index,
// so the meeting vanishes with no error shown — and `orphanedRecordings()` hides it too (F187).
@Test("Recording is refused while degraded, before any folder or state changes")
@MainActor
func degradedLibraryRefusesRecording() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F187.\(UUID().uuidString)")!
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.startRecording()

    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: recordings.path))
    #expect(model.recordingState == .idle)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// Defense in depth: even if a future caller skips the AppModel guard, the store itself never lays down
// a recording folder it could not index (F187).
@Test("recordingDirectory(for:) throws while degraded and creates nothing")
@MainActor
func degradedRecordingDirectoryThrows() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()

    #expect(throws: MeetingStoreError.libraryIsReadOnly) {
        try store.recordingDirectory(for: id)
    }
    #expect(!FileManager.default.fileExists(atPath: store.recordingDirectoryURL(for: id).path))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Recordings", isDirectory: true).path
    ))
}
