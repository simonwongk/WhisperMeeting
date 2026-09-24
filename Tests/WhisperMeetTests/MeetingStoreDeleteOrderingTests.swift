import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F190 Task 1 — the caller-side half, which is a data-loss hazard *today* and does not depend on
/// any new write protocol.
///
/// `AGENTS.md` already states the rule: "`delete` removes audio before it saves the index, so
/// blocking persistence alone is not enough." `delete(id:)` calls `removeRecordingDirectory` and
/// only then `persistMeetings()`, so any persist failure leaves an index entry pointing at audio
/// that is already gone. It is compounded by `storageErrorMessage = nil` on the line after
/// `persistMeetings()`, which wipes the very message the failed persist just set — so the user is
/// told nothing at all.
///
/// The same shape costs an edit in `flushPendingEdits()`, which clears `pendingIndexFlush` before
/// persisting, leaving nothing to re-attempt when the persist fails.

@MainActor
private func makeLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingStoreDeleteOrdering-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

/// Makes the library root refuse new writes, which is how a full disk or a permissions problem
/// reaches `save()`. Restored by the caller's `defer` so the directory can be removed.
private func denyWrites(to root: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
}

private func allowWrites(to root: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
}

@MainActor
@Test("A failed index save during delete leaves the recording on disk (F190)")
func deleteDoesNotDestroyAudioWhenTheIndexCannotBeSaved() throws {
    let root = try makeLibrary()
    defer {
        allowWrites(to: root)
        try? FileManager.default.removeItem(at: root)
    }

    let store = MeetingStore(rootDirectory: root)
    let folder = root
        .appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent("session-1", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = folder.appendingPathComponent("meeting.wav")
    try Data("audio".utf8).write(to: recording)

    let meeting = MeetingRecord(
        title: "Quarterly planning",
        recordingPath: "Recordings/session-1/meeting.wav"
    )
    store.upsert(meeting)
    #expect(FileManager.default.fileExists(atPath: recording.path))

    // From here the index cannot be written. Today the audio is destroyed anyway.
    try denyWrites(to: root)
    store.delete(id: meeting.id)

    #expect(
        FileManager.default.fileExists(atPath: recording.path),
        "audio must survive when the index that references it could not be saved"
    )
    #expect(
        store.storageErrorMessage != nil,
        "a failed delete must tell the user something — the nil-ing after persistMeetings() wipes it"
    )
}

@MainActor
@Test("A failed flush keeps the pending edit so a later flush retries it (F190)")
func failedFlushKeepsThePendingEditForRetry() async throws {
    let root = try makeLibrary()
    defer {
        allowWrites(to: root)
        try? FileManager.default.removeItem(at: root)
    }

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    let meeting = MeetingRecord(title: "Design review", recordingPath: "Recordings/s/meeting.wav")
    store.upsert(meeting)

    // Schedule a debounced edit, then make the index unwritable before it is flushed.
    store.editTranscript(id: meeting.id, text: "the edited transcript")
    try denyWrites(to: root)
    store.flushPendingEdits()
    #expect(store.storageErrorMessage != nil)

    // The edit must still be pending: nothing else will ever re-attempt it.
    allowWrites(to: root)
    store.flushPendingEdits()

    let reloaded = MeetingStore(rootDirectory: root)
    let saved = try #require(reloaded.meetings.first { $0.id == meeting.id })
    #expect(saved.transcriptText == "the edited transcript")
}

// MARK: - F451: the batch path is the one the UI calls

/// Meetings that each own a real `Recordings/<id>/meeting.wav`, the shape every recording and
/// import produces.
@MainActor
private func seedMeetings(_ titles: [String], in root: URL, store: MeetingStore) throws -> [UUID] {
    var ids: [UUID] = []
    for title in titles {
        let id = UUID()
        let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
        store.upsert(MeetingRecord(
            id: id,
            title: title,
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed
        ))
        ids.append(id)
    }
    return ids
}

/// F190 fixed `delete(id:)`, which nothing in the UI calls. Every delete the user can make — the
/// confirmation dialog for one meeting and the batch bar for several — goes through
/// `AppModel.deleteMeetings(ids:)` and so `delete(ids:)`, which still removed the folders first.
@MainActor
@Test("A failed index save during a UI delete leaves every recording on disk (F451)")
func uiDeleteDoesNotDestroyAudioWhenTheIndexCannotBeSaved() throws {
    let root = try makeLibrary()
    defer {
        allowWrites(to: root)
        try? FileManager.default.removeItem(at: root)
    }
    let store = MeetingStore(rootDirectory: root)
    let ids = try seedMeetings(["Budget review", "Hiring sync"], in: root, store: store)
    let defaults = try #require(UserDefaults(suiteName: "F451-\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    // From here the index cannot be written; the Recordings folder itself still can be.
    try denyWrites(to: root)
    model.deleteMeetings(ids: ids)

    for id in ids {
        let audio = root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav")
        #expect(
            FileManager.default.fileExists(atPath: audio.path),
            "audio must survive when the index that references it could not be saved"
        )
    }
    #expect(Set(store.meetings.map(\.id)) == Set(ids), "memory must match the index still on disk")
    #expect(store.storageErrorMessage != nil, "the failed save must be reported")
    #expect(store.pendingShreds.isEmpty, "nothing was deleted, so nothing may be queued to shred")

    allowWrites(to: root)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(Set(reopened.meetings.map(\.id)) == Set(ids))
}
