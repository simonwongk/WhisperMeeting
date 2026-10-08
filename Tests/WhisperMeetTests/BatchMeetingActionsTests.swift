import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

/// A writable library holding `count` meetings, each with a real recording directory and a file in it.
@MainActor
private func makeLibrary(count: Int) throws -> (MeetingStore, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    var ids: [UUID] = []
    for index in 0..<count {
        let id = UUID()
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
        store.upsert(MeetingRecord(
            id: id,
            title: "Meeting \(index)",
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed,
            transcriptText: "transcript \(index)"
        ))
        ids.append(id)
    }
    return (store, root, ids)
}

@Test("Deleting several meetings writes the index once, not once per meeting")
@MainActor
func batchDeleteWritesTheIndexOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.delete(ids: ids)

    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == before + 1)
    for id in ids {
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Test("A meeting whose directory cannot be removed is kept, and the rest still delete")
@MainActor
func batchDeleteKeepsWhatItCouldNotRemove() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let stubborn = ids[1]
    store.removeRecordingDirectory = { url in
        if url.lastPathComponent == stubborn.uuidString {
            throw NSError(domain: "test", code: 1)
        }
        try FileManager.default.removeItem(at: url)
    }

    store.delete(ids: ids)

    #expect(store.meetings.map(\.id) == [stubborn])
    #expect(store.storageErrorMessage != nil)
    // And on disk. Since F451 the index is saved without all three BEFORE any folder is touched,
    // so it is the second, restoring save that brings the stubborn one back after a relaunch.
    #expect(MeetingStore(rootDirectory: root).meetings.map(\.id) == [stubborn])
    #expect(!store.pendingShreds.keys.contains(stubborn), "a kept meeting is not queued to shred")
}

@Test("Batch delete is refused while the library is read-only, and removes no audio")
@MainActor
func batchDeleteRefusedWhileDegraded() throws {
    // Seed a writable library, then corrupt only the primary index so the backup loads:
    // that yields `.recoveredFromBackup`, which is degraded AND still has records and audio.
    let (_, root, ids) = try makeLibrary(count: 2)
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    // `BackupJSONStore.save()` writes the PREVIOUS primary into the backup, so after two upserts the
    // backup is one generation behind and holds only one meeting. Copy the primary across first, or
    // this fixture silently tests a one-record library and the count assertion below is meaningless.
    try? FileManager.default.removeItem(at: backup)
    try FileManager.default.copyItem(at: primary, to: backup)
    try Data("broken-primary".utf8).write(to: primary)

    let store = MeetingStore(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(store.meetings.count == 2)
    let before = store.persistCount
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(ids: ids)

    #expect(!removalAttempted)
    #expect(store.meetings.count == 2)
    #expect(store.persistCount == before)
    for id in ids {
        let wav = root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }
    #expect(store.storageErrorMessage != nil)
}

@Test("Adding a tag to several meetings writes the index once and applies to all")
@MainActor
func batchAddTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.setTags(id: ids[0], ["existing"])
    let before = store.persistCount

    store.addTag("  Budget  ", to: ids)

    #expect(store.persistCount == before + 1)
    for id in ids {
        let tags = store.meeting(id: id)?.tags ?? []
        #expect(tags.contains("Budget"))          // trimmed by MeetingTags.normalized
    }
    #expect(store.meeting(id: ids[0])?.tags?.contains("existing") == true)
}

@Test("Removing a tag takes it off every selected meeting and leaves others alone")
@MainActor
func batchRemoveTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.addTag("shared", to: ids)
    store.setTags(id: ids[2], ["shared", "keep"])
    let before = store.persistCount

    store.removeTag("shared", from: [ids[0], ids[2]])

    #expect(store.persistCount == before + 1)
    #expect(store.meeting(id: ids[0])?.tags?.contains("shared") != true)
    #expect(store.meeting(id: ids[1])?.tags?.contains("shared") == true)
    #expect(store.meeting(id: ids[2])?.tags == ["keep"])
}

/// A transcription held open until it is cancelled or released, recording which of the two ended it
/// (F441): "the job finished" and "the job was stopped" must not be mistakable for each other.
private final class CancellableRun: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled = false
    private var _released = false
    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func release() { lock.withLock { _released = true } }

    struct NeverEnded: Error {}

    func run() async throws {
        lock.withLock { _started = true }
        do {
            for _ in 0..<6_000 {
                if lock.withLock({ _released }) { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        throw NeverEnded()
    }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

// F441: this seeded `.completed` meetings, queued nothing, and asserted nobody was queued — true before
// and after the call whatever `deleteMeetings` did, so removing the `cancelTranscription` loop left it
// green. It now has one transcription running and one waiting, deletes both, and requires the running
// one to have been cancelled and the waiting one dropped. (F666's `standingDeleteStopsRunningAndQueued
// Transcriptions` reaches the same path with a full fixture library; this one is the batch-delete
// path the library view calls, on the plain batch fixture.)
@Test("Deleting a selection cancels each meeting's transcription first")
@MainActor
func batchDeleteCancelsTranscriptions() async throws {
    let (store, root, ids) = try makeLibrary(count: 2)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "BatchDelete-\(UUID().uuidString)"))
    // Pinned installed, so both requests reach the queue on any host.
    let model = AppModel(
        store: store, recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.selectedEngine = .whisperLarge
    // The fixture's meetings are `.completed`; a transcription needs them waiting for one.
    for id in ids { store.update(id: id) { $0.status = .recorded; $0.transcriptText = "" } }
    let (running, waiting) = (ids[0], ids[1])
    let run = CancellableRun()
    defer { run.release() }
    model.runTranscriptionEngineOverride = { _, _ in
        try await run.run()
        return TranscriptionResult(id: "stub", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [])
    }

    model.beginTranscription(id: running)
    try await waitUntil("the first transcription to start") { run.started }
    model.beginTranscription(id: waiting)
    try #require(model.hasActiveTranscription, "the first transcription is not the running job")
    try #require(model.isQueuedForTranscription(waiting), "the second meeting never queued")

    model.deleteMeetings(ids: ids)

    try #require(store.meetings.isEmpty, "the delete was meant to stand")
    #expect(!model.isQueuedForTranscription(waiting), "a deleted meeting is still waiting to be transcribed")
    try await waitUntil("the running transcription to end") { !model.hasActiveTranscription }
    #expect(run.cancelled, "the deleted meeting's running transcription was not stopped")
    #expect(!model.hasQueuedTranscriptions)
}
