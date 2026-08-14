import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F187 — the empty-index heuristic, asserted in BOTH directions.
//
// `MeetingStore.loadMeetings()` degrades to `.suspectEmpty` when an index decodes cleanly to zero
// meetings while recording folders exist on disk, and `.suspectEmpty` makes the WHOLE library
// read-only with no in-app way out. That is right for the shape it was written for — an index
// truncated to `[]` next to recordings that really happened — and wrong for the shape it also
// matched: a single UNFINISHED recording folder, which the app creates BEFORE the meeting record
// exists (`AppModel.startRecording` → `store.recordingDirectory(for:)`). Deleting the last meeting
// legitimately writes `[]`, so "empty index + one folder from a force-quit recording" locked the
// library over a state with no corruption in it at all.
//
// Tests 1–2 are the false positive; tests 3–5 are the wipe shape that must still be caught, so
// narrowing the rule into uselessness fails here rather than in the field.

// MARK: - Fixtures

private func makeLibraryRoot(_ label: String) throws -> URL {
    // Temp + UUID: a test must never touch ~/Library/Application Support/WhisperMeet.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F187-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// The index exactly as `persistMeetings()` writes it after the user deletes their last meeting:
/// valid JSON, zero records. This — not a corrupt file — is the precondition for `.suspectEmpty`.
private func writeEmptyIndex(in root: URL) throws {
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
}

@discardableResult
private func makeRecordingFolder(in root: URL) throws -> URL {
    let folder = root
        .appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// What a force-quit mid-recording actually leaves behind: the two raw capture tracks
/// `AudioCaptureEngine.start` opens, and nothing else. `meeting.wav` is written only by
/// `AudioCaptureEngine.stop()`, so its absence is what "this recording never finished" looks like.
private func writeInterruptedCapture(in folder: URL, seconds: Int = 1) throws {
    let samples = [Float](repeating: 0.25, count: 48_000 * seconds)
    let data = samples.withUnsafeBytes { Data($0) }
    try data.write(to: folder.appendingPathComponent("system-audio.f32"))
    try data.write(to: folder.appendingPathComponent("microphone-audio.f32"))
}

/// A complete WAV: header plus the payload it declares, so `InterruptedRecordingRecovery`'s duration
/// probe reads it as playable rather than truncated.
private func finishedWAV(seconds: UInt32 = 1) -> Data {
    let dataByteCount = 48_000 * 2 * seconds
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    return wav
}

/// A recording that finished: the mixed WAV plus the manifest `stop()` writes beside it.
private func writeFinishedCapture(in folder: URL, named name: String = "meeting.wav") throws {
    try finishedWAV().write(to: folder.appendingPathComponent(name))
    try Data(#"{"systemAudio":{},"microphoneAudio":{}}"#.utf8)
        .write(to: folder.appendingPathComponent("source-tracks.json"))
}

// MARK: - 1. The false positive must be gone

@Test("An empty index beside one unfinished recording folder loads complete and stays writable")
@MainActor
func suspectEmptyIgnoresAnUnfinishedRecordingFolder() throws {
    let root = try makeLibraryRoot("unfinished")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    try writeInterruptedCapture(in: try makeRecordingFolder(in: root))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.health == .complete)
    #expect(!store.isDegraded)

    // Writable means the two things `.suspectEmpty` takes away. Recording first: this is the exact
    // call `AppModel.startRecording` makes, and the throw is what makes the library unusable.
    let id = UUID()
    let directory = try store.recordingDirectory(for: id)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    // Then a mutation that must reach disk, proven by reopening the library rather than by reading
    // back the in-memory array a refused mutator would also leave untouched.
    store.upsert(MeetingRecord(
        id: id,
        title: "A meeting recorded after the interruption",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav"
    ))
    #expect(store.storageErrorMessage == nil)
    #expect(MeetingStore(rootDirectory: root).meetings.map(\.id) == [id])
}

@Test("An interrupted recording beside an empty index is rebuilt instead of stranded")
@MainActor
func suspectEmptyLeavesAnInterruptedRecordingRecoverable() async throws {
    let root = try makeLibraryRoot("recoverable")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    let folder = try makeRecordingFolder(in: root)
    try writeInterruptedCapture(in: folder)

    let store = MeetingStore(rootDirectory: root)
    let suite = "F187.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.performStartupRecovery()

    // The whole cost of the false positive: while degraded, `orphanedRecordings()` returns [], so the
    // audio of the interrupted meeting is never rebuilt and the user is never told it exists.
    #expect(store.meetings.count == 1)
    #expect(store.meetings.first?.title.hasPrefix("Recovered Meeting") == true)
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
}

// MARK: - 2. The real wipe shape must still be caught

@Test("An empty index beside finished recordings still degrades to suspectEmpty")
@MainActor
func suspectEmptyStillCatchesAWipedIndexNextToFinishedRecordings() throws {
    let root = try makeLibraryRoot("wiped")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    try writeFinishedCapture(in: try makeRecordingFolder(in: root))
    try writeFinishedCapture(in: try makeRecordingFolder(in: root))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.health == .suspectEmpty(recordingFolderCount: 2))
    #expect(store.isDegraded)

    // Read-only in the two ways that matter: no new recording folder, and no write over the index
    // that still might be recoverable.
    let id = UUID()
    #expect(throws: MeetingStoreError.libraryIsReadOnly) {
        try store.recordingDirectory(for: id)
    }
    let before = store.persistCount
    store.upsert(MeetingRecord(id: id, title: "Should never be written"))
    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == before)
    #expect(store.storageErrorMessage != nil)
    #expect(try Data(contentsOf: root.appendingPathComponent("meetings.json")) == Data("[]".utf8))
}

@Test("Only folders holding a finished recording are counted as evidence of a wipe")
@MainActor
func suspectEmptyCountsOnlyFinishedRecordingFolders() throws {
    let root = try makeLibraryRoot("mixed")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    try writeFinishedCapture(in: try makeRecordingFolder(in: root))
    try writeInterruptedCapture(in: try makeRecordingFolder(in: root))

    let store = MeetingStore(rootDirectory: root)

    // One finished recording is still the wipe shape; the interrupted folder next to it contributes
    // nothing, because it is evidence of a crash rather than of a meeting the index has lost.
    #expect(store.health == .suspectEmpty(recordingFolderCount: 1))
    #expect(store.isDegraded)
}

@Test("A recovered WAV and an imported file count as finished recordings")
@MainActor
func suspectEmptyCountsRecoveredAndImportedRecordings() throws {
    let root = try makeLibraryRoot("markers")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    // Both are meetings that exist for the user: the first was rebuilt by a previous recovery pass
    // under its own name, the second was imported and never had capture tracks at all. Keying the
    // rule to `meeting.wav` alone would miss both, so a wiped library of imports would look fresh.
    try writeFinishedCapture(in: try makeRecordingFolder(in: root), named: "meeting-recovered.wav")
    try Data("fake compressed audio".utf8)
        .write(to: try makeRecordingFolder(in: root).appendingPathComponent("recording.m4a"))
    try writeInterruptedCapture(in: try makeRecordingFolder(in: root))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.health == .suspectEmpty(recordingFolderCount: 2))
    #expect(store.isDegraded)
}
