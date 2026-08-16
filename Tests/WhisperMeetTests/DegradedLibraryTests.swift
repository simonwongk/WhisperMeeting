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
///
/// `status`, `segments` and `recordingBytes` are parameters (with the original defaults) because the
/// engine-running mutators need more than a bare record to reach their guard: `computeSecondOpinion`
/// returns early unless the meeting is `.completed` with segments, and `reTranscribeSegment` slices
/// the recording as a canonical WAV before it runs anything. Seeding a five-byte "audio" placeholder
/// there would make the clip step throw and the guard never be the thing under test (F187).
@MainActor
private func makeBackupRecoveredStore(
    status: MeetingStatus = .recorded,
    segments: [TranscriptSegment] = [],
    recordingBytes: Data = Data("audio".utf8)
) throws -> (store: MeetingStore, root: URL, meeting: MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetRecovered-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try recordingBytes.write(to: directory.appendingPathComponent("meeting.wav"))

    let meeting = MeetingRecord(
        id: id,
        title: "Quarterly review",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: status,
        transcriptText: "the original transcript",
        segments: segments,
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
    // The orphan-adoption message as it is worded TODAY. Asserting the pre-rename wording here would
    // be true by construction and could never fail, which is how this assertion originally shipped.
    #expect(!alert.contains("was added back to meeting history"))
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
    #expect(store.meeting(id: meeting.id)?.summary == nil)
    let message = try #require(model.alertMessage)
    #expect(message.contains("Summarization cannot start"))
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// MARK: - Second opinion (F187)

/// Counts engine invocations across the `@Sendable`-adjacent stub boundary.
private final class EngineCallCounter: @unchecked Sendable {
    var runs = 0
}

@MainActor
private func stubEngine(_ model: AppModel, counter: EngineCallCounter) {
    model.runTranscriptionEngineOverride = { _, _ in
        counter.runs += 1
        return TranscriptionResult(
            id: "stub", text: "a different reading", languageCode: "en",
            audioDuration: 2, confidence: nil,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "a different reading")]
        )
    }
}

// The most expensive refusal in the app: a second opinion is a whole SECOND ASR pass over the entire
// recording — minutes to tens of minutes. Its only product, `secondOpinionSpans`, is consumable solely
// through `applySecondOpinionSpan`, whose `store.update` a degraded store refuses. Without a guard the
// user waits out a full re-transcription, reads the comparison sheet, clicks Replace on each
// divergence, and every click silently does nothing (F187).
@Test("Requesting a second opinion is refused while degraded, before the engine flag is claimed")
@MainActor
func degradedLibraryRefusesSecondOpinionRequest() throws {
    let (store, root, meeting) = try makeBackupRecoveredStore(
        status: .completed,
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "the original transcript")]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    model.requestSecondOpinion(id: meeting.id)

    // Both are set synchronously by the un-refused path, before the worker task is even spawned — so
    // they are the state that proves the refusal happened at the entry point, not inside the task.
    #expect(!model.isRunningAuxiliaryEngine)
    #expect(model.secondOpinionRunningID == nil)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
    #expect(message.contains("second opinion"))
}

@Test("The second-opinion worker refuses while degraded and never starts the other engine")
@MainActor
func degradedLibraryRefusesSecondOpinionWork() async throws {
    let (store, root, meeting) = try makeBackupRecoveredStore(
        status: .completed,
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "the original transcript")]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    let counter = EngineCallCounter()
    stubEngine(model, counter: counter)

    await model.computeSecondOpinion(id: meeting.id)

    #expect(counter.runs == 0)
    #expect(model.secondOpinionSpans == nil)
    // A refusal is not an engine failure: the sheet must not render "the comparison failed".
    #expect(!model.secondOpinionFailed)
    let message = try #require(model.alertMessage)
    #expect(message.contains("second opinion"))
    #expect(message.contains("read-only"))
}

// MARK: - The backstop under every engine path (F187)

// Three consecutive briefs on this branch enumerated "all the mutating entry points" by grepping for
// `store.upsert`/`store.update` call sites, and all three missed one — because the expensive work and
// the write live in different functions. `executeEngine` is the single admission point for every heavy
// engine pass (second opinion, segment re-run, full transcription), so it refuses on its own account:
// whatever entry point someone adds next, no minutes-long model run can start against a library that
// cannot save the result.
@Test("No engine pass can start while degraded, not even a stubbed one")
@MainActor
func degradedLibraryRefusesEveryEngineRun() async throws {
    let (store, root, meeting) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    let counter = EngineCallCounter()
    stubEngine(model, counter: counter)
    let selection = MeetingTranscriptionSelection(engine: model.selectedEngine, language: model.selectedLanguage)

    var thrown: Error?
    do {
        _ = try await model.executeEngine(selection, on: store.recordingURL(for: meeting))
    } catch {
        thrown = error
    }

    #expect(thrown as? MeetingStoreError == .engineRunIsReadOnly)
    // The refusal precedes the override branch, so even a test double never runs.
    #expect(counter.runs == 0)
    // It names transcription, not recording: this backstop is reachable from every engine path.
    let message = try #require((thrown as? MeetingStoreError)?.errorDescription)
    #expect(message.contains("Transcription cannot start"))
    #expect(message.contains("read-only"))
}

// MARK: - Guards that were load-bearing but untested (F187)

/// Counts the link-import network seams so a removed guard shows up as work actually attempted, not
/// just as a nil return that the guard and a later failure would both produce.
private final class NetworkSeamCounter: @unchecked Sendable {
    var probes = 0
    var downloads = 0
    var captionFetches = 0
}

// The worst instance of the whole bug. `importFromURL` creates the meeting directory, writes the
// provenance sidecar, and pulls the media DOWN OVER THE NETWORK, and only then reaches the `upsert`
// inside `adoptImportedRecording` that a degraded store refuses — leaving the download sitting in the
// library, unindexed, while `orphanedRecordings()` reports nothing because the index is degraded.
// The network seams are stubbed with a real (tiny) file, exactly as `MediaURLImportTests` does, so
// removing the guard costs a folder on disk rather than a real request.
@Test("A link import is refused while degraded, before the probe or the download")
@MainActor
func degradedLibraryRefusesLinkImport() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    model.linkImportEnabled = true // off by default; opt in so the feature flag cannot be the refusal
    let network = NetworkSeamCounter()
    model.probeMediaURL = { _ in
        network.probes += 1
        return MediaProbe(title: "Quarterly review", durationSeconds: 600, uploader: "Acme", language: "en")
    }
    model.downloadMedia = { _, directory, _ in
        network.downloads += 1
        let file = directory.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: file)
        return file
    }
    model.downloadCaptions = { _, _, _ in
        network.captionFetches += 1
        return []
    }

    let imported = await model.importFromURL("https://www.youtube.com/watch?v=abc123")

    #expect(imported == nil)
    #expect(network.probes == 0)
    #expect(network.downloads == 0)
    #expect(network.captionFetches == 0)
    #expect(store.meetings.isEmpty)
    #expect(!model.isImporting)
    // Nothing was laid down: no meeting folder, so no sidecar and no unindexed audio.
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: recordings.path))
    let message = try #require(model.alertMessage)
    #expect(message.contains("Import cannot start"))
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// The segment re-run reaches the engine through `makeSegmentClip`, which reads and slices the real
// recording, and only then hits a `store.update` a degraded store refuses. The seed here is a genuine
// 48 kHz WAV so the clip step CANNOT be what stops it — with the guard removed this walks all the way
// to `executeEngine`, and the message the user sees changes from the specific one to the backstop's
// generic one. That message is what makes this test genuinely red without its guard.
@Test("Re-transcribing a segment is refused while degraded, with the specific reason")
@MainActor
func degradedLibraryRefusesSegmentReTranscription() async throws {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "first"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "second wrong")
    ]
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: 48_000 * 2 * 3)
    wav.append(Data(count: 48_000 * 2 * 3))
    let (store, root, meeting) = try makeBackupRecoveredStore(
        status: .completed, segments: segments, recordingBytes: wav
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    let counter = EngineCallCounter()
    stubEngine(model, counter: counter)

    await model.reTranscribeSegment(id: meeting.id, index: 1)

    #expect(counter.runs == 0)
    #expect(store.meeting(id: meeting.id)?.segments.map(\.text) == ["first", "second wrong"])
    let message = try #require(model.alertMessage)
    // Named by the action the user actually took — not the backstop's generic "Transcription", which
    // is what surfaces if this entry point's own guard is deleted.
    #expect(message.contains("Re-transcribing a segment cannot start"))
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// MARK: - Backup (F187)

/// Counts real coordinator invocations across the `@Sendable` backup seam.
private final class BackupCallCounter: @unchecked Sendable {
    var runs = 0
}

/// Every path under `directory`, keyed by kind + relative path, with each file's exact bytes — the
/// whole destination as one comparable value, so "nothing was created and nothing was pruned" is a
/// single assertion about real disk state rather than a list of guesses about what a run would touch.
private func snapshot(of directory: URL) throws -> [String: Data] {
    let fileManager = FileManager.default
    let base = directory.standardizedFileURL.path
    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [:] }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { continue }
        let relative = String(full.dropFirst(base.count + 1))
        let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        // Kind is part of the key so an empty file can never compare equal to a directory it replaced.
        result[(isDirectory ? "dir:" : "file:") + relative] = isDirectory ? Data() : try Data(contentsOf: url)
    }
    return result
}

// The most intuitive thing a user does when the library goes read-only — "back this up before I touch
// anything" — is the click that destroys their last good off-library copies. `backUpLibrary` snapshots
// the DAMAGED `meetings.json` into a new generation and then prunes complete generations beyond the
// retention limit, so a few clicks replace every off-library copy of the readable index with copies of
// the truncated one. The seam here forwards to the REAL coordinator, so without the guard this test
// does that damage on actual disk instead of watching a stub return early (F187).
@Test("Backing up while degraded creates no generation and prunes no existing one")
@MainActor
func degradedLibraryRefusesBackUp() async throws {
    let (store, root, _) = try makeBackupRecoveredStore()
    defer { try? FileManager.default.removeItem(at: root) }
    // Outside the library — the coordinator refuses an overlapping destination outright, and that
    // refusal would stand in for the guard being tested.
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("F187-backup-dest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: destination) }

    // A plausible existing generation: the user's last good off-library copy of a READABLE index.
    let existing = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent("1000", isDirectory: true)
    let existingIndex = existing.appendingPathComponent("meetings.json")
    let existingAudio = existing.appendingPathComponent("Recordings/A/meeting.wav")
    try FileManager.default.createDirectory(
        at: existingAudio.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("the last readable index".utf8).write(to: existingIndex)
    try Data("audio-A".utf8).write(to: existingAudio)
    try Data().write(to: existing.appendingPathComponent(BackupCoordinator.completionMarker))
    let before = try snapshot(of: destination)

    let defaults = try #require(UserDefaults(suiteName: "F187.\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    // One more generation is one too many: a real run at this retention prunes generation 1000.
    model.backupRetention = 1
    let counter = BackupCallCounter()
    model.runLibraryBackup = { source, destination, now, retain in
        counter.runs += 1
        return try BackupCoordinator.backUp(source: source, destination: destination, now: now, retain: retain)
    }

    await model.backUpLibrary(to: destination, now: 5_000)

    // The work never started — not "a stub returned early".
    #expect(counter.runs == 0)
    let after = try snapshot(of: destination)
    #expect(after == before) // byte-for-byte: nothing created, nothing pruned, nothing rewritten
    #expect(FileManager.default.fileExists(atPath: existingIndex.path))
    // `try?`, not `try`: a pruned generation must still record every remaining expectation below
    // rather than aborting the test at the first missing file.
    #expect((try? Data(contentsOf: existingIndex)) == Data("the last readable index".utf8))
    let created = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent("5000", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: created.path))
    let message = try #require(model.alertMessage)
    // Named by the action the user took, and never the success summary a completed run would post.
    #expect(message.contains("Backing up the library cannot start"))
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}
