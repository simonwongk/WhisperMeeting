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

// Startup is where the damage happened: with an empty in-memory index every recording folder looks
// orphaned, so "recovery" rebuilt ten real meetings as blank stubs. A degraded library must report the
// state and change nothing (F187).
@Test("Startup recovery creates no records when the index is degraded")
@MainActor
func startupRecoverySuppressedWhileDegraded() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<3 {
        let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let defaults = try #require(UserDefaults(suiteName: "DegradedLibraryTests-\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.performStartupRecovery()

    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == 0)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("read-only"))
    #expect(!alert.contains("added it back to meeting history"))
}

// MARK: - Work that runs to completion before its write is refused (F187)
//
// `store.upsert`/`store.update` decline while degraded, silently. Import, transcription and
// summarization all reach that write only at the END of their job — after the media file has been
// copied into the library, after a speech model has run for minutes, after a Claude call has been
// spent. Each must refuse UP FRONT, so nothing is done and the user is told why.

@Test("Import is refused while degraded, before any audio is copied into the library")
@MainActor
func degradedLibraryRefusesImport() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("F187-import-source-\(UUID().uuidString).wav")
    try Data("source audio".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    let imported = await model.importRecording(from: source, title: "Imported")

    #expect(imported == nil)
    #expect(store.meetings.isEmpty)
    #expect(!model.isImporting)
    // The point of the task: the copy must not have happened. Without the guard the audio lands in
    // the library and the concluding `upsert` is refused, so it sits there unindexed and unreported.
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: recordings.path))
    #expect(FileManager.default.fileExists(atPath: source.path)) // the user's own file is untouched
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

@Test("Transcription is refused while degraded, before the engine is started")
@MainActor
func degradedLibraryRefusesTranscription() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    model.beginTranscription(id: meeting.id)

    // Real state `beginTranscription` sets on success — the queue it enqueues into and then pumps.
    #expect(!model.transcription.contains(meeting.id))
    #expect(model.activeTranscriptionID == nil)
    #expect(store.meeting(id: meeting.id)?.transcriptText == meeting.transcriptText)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// The bulk entry point is guarded as well as its delegate, so it cannot report a count for work it
// never started — the seeded meeting is `.recorded` with audio, so it IS a queue candidate (F187).
@Test("Transcribe-all is refused while degraded and reports having started nothing")
@MainActor
func degradedLibraryRefusesTranscribeAll() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    try #require(model.readyToTranscribeMeetings.map(\.id) == [meeting.id])

    #expect(model.beginTranscriptionForAllReady() == 0)

    #expect(!model.transcription.contains(meeting.id))
    #expect(model.activeTranscriptionID == nil)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// The local model is stubbed installed so the engine precondition cannot be what stops this — only
// the read-only guard can. Without it, `summarize` claims the summarization slot and spawns the job,
// which would spend a Claude API call for a summary the store then refuses to save (F187).
@Test("Summarizing is refused while degraded, before a model runs or an API call is spent")
@MainActor
func degradedLibraryRefusesSummarize() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }

    model.summarize(id: meeting.id)

    // `activeSummarizationID` is set in the same breath as `summarizationTasks[id]`, and is the
    // observable half of that pair — `localSummarizePathStoresSummary` asserts on it for the
    // success case, so a registered task and a nil id cannot coexist.
    #expect(model.activeSummarizationID == nil)
    #expect(!model.isSummarizing)
    #expect(store.meeting(id: meeting.id)?.summary == nil)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}
