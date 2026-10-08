import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F870 (and F867) — F849's race, for the writers it left: Shrink, Rebuild Audio and the launch
// notes.md backfill each write into a meeting's folder from a detached task. `MeetingStore.delete`
// removes the folder on the main actor in two halves, its contents and then the folder; a file a
// writer creates in between makes the folder's removal fail, and F146's rollback lists the meeting
// again after its audio is gone. Each test holds that interleave open with two seams — the writer,
// which waits until the removal has emptied the folder, and the removal, which lets the writer land
// before taking the folder itself — and asks what a delete does now: refuse a meeting a writer
// holds, so nothing is half-deleted, and delete it normally once the writer is done.

/// Where the writer is, set from whichever thread each seam runs on.
private final class WriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var landed = false

    var hasEntered: Bool { lock.withLock { entered } }
    var isReleased: Bool { lock.withLock { released } }
    var hasLanded: Bool { lock.withLock { landed } }
    func enter() { lock.withLock { entered = true } }
    func release() { lock.withLock { released = true } }
    func land() { lock.withLock { landed = true } }

    /// A bounded poll on this gate's own state, blocking the calling thread. Large, because the
    /// subject is an ordering, not a speed; false only if the other side never arrived.
    func block(until condition: (WriterGate) -> Bool, seconds: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(self) {
            guard Date() < deadline else { return false }
            usleep(1_000)
        }
        return true
    }
}

/// FileManager's recursive removal in its two halves, with the writer let in between.
@MainActor
private func removeInTwoHalves(_ store: MeetingStore, letting gate: WriterGate) {
    store.removeRecordingDirectory = { directory in
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
        gate.release()
        if gate.hasEntered, !gate.block(until: { $0.hasLanded }) { Issue.record("the writer never landed") }
        guard rmdir(directory.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
    }
}

/// Waits, on the main actor, for the writer to be inside its write.
@MainActor
private func waitUntilEntered(_ gate: WriterGate) async throws {
    let deadline = Date().addingTimeInterval(60)
    while !gate.hasEntered, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    try #require(gate.hasEntered, "the writer never started")
}

/// A finished capture: a real 60 s WAV, both raw tracks with a matching manifest (Shrink and Rebuild
/// Audio both refuse a folder that reads as damaged), and notes.md.
private func writeCapture(in folder: URL, recordingName: String = "meeting.wav") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 60 * 48_000), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent(recordingName))
    let trackBytes = 6_000_000
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try Data(count: trackBytes).write(to: folder.appendingPathComponent(name))
    }
    try Data("""
        {"systemAudio":{"file":"system-audio.f32","frameCount":\(trackBytes / 4)},
         "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(trackBytes / 4)}}
        """.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
    try Data(count: 50).write(to: folder.appendingPathComponent("notes.md"))
}

@MainActor
private func makeModel(_ name: String) throws -> (AppModel, UUID, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F870-\(name)-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try writeCapture(in: folder)
    let model = AppModel(store: MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999),
                         recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(
        id: id, title: "Weekly sync", duration: 60, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "Hi."
    ))
    return (model, id, folder, root)
}

@MainActor
@Test("A delete while Shrink is compressing the meeting is refused, never half-done, and works once Shrink finishes (F870)")
func deleteDuringShrinkIsRefused() async throws {
    let (model, id, folder, root) = try makeModel("shrink")
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = folder.appendingPathComponent("meeting.wav")
    let gate = WriterGate()
    model.encodeForShrink = { _, output, _ in
        gate.enter()
        defer { gate.land() }
        guard gate.block(until: { $0.isReleased }) else { Issue.record("the encode was never let go"); return }
        try Data(count: 15_000).write(to: output)
    }
    model.decodedDurationForShrink = { _ in 60 }
    model.declaredDurationForShrink = { _ in 60 }
    model.availableBytesForShrink = { _ in .max }
    removeInTwoHalves(model.store, letting: gate)

    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    let shrink = try #require(model.performShrink(confirmed: true))
    try await waitUntilEntered(gate)

    model.deleteMeetings(ids: [id])

    let listed = model.store.meeting(id: id) != nil
    #expect(!listed || FileManager.default.fileExists(atPath: wav.path),
            "the delete half-completed: the meeting is listed again without its audio")
    #expect(listed, "a delete while Shrink holds the meeting's folder is refused, not raced")
    #expect(model.store.storageErrorMessage == MeetingStore.busyFolderDeleteMessage(["Weekly sync"]))

    gate.release()
    await shrink.value
    // Shrink is done: the same delete now goes through, folder and all.
    model.deleteMeetings(ids: [id])
    #expect(model.store.meeting(id: id) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@MainActor
@Test("A delete while Rebuild Audio is writing the meeting's audio is refused, never half-done (F870)")
func deleteDuringRebuildIsRefused() async throws {
    let (model, id, folder, root) = try makeModel("rebuild")
    defer { try? FileManager.default.removeItem(at: root) }
    // Rebuild Audio is offered only for a recovered meeting: no complete meeting.wav (F255, F500).
    try FileManager.default.removeItem(at: folder.appendingPathComponent("meeting.wav"))
    let wav = folder.appendingPathComponent("meeting-recovered.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000).write(to: wav)
    model.store.update(id: id) {
        $0.recordingPath = "Recordings/\(id.uuidString)/meeting-recovered.wav"
        $0.duration = 0.1
    }
    let gate = WriterGate()
    model.performSourceTracksRebuild = { offer in
        gate.enter()
        defer { gate.land() }
        guard gate.block(until: { $0.isReleased }) else { Issue.record("the rebuild was never let go"); return nil }
        // What the rebuild writes into the folder while it works, beside the tracks it reads.
        try Data(count: 64).write(to: offer.directory.appendingPathComponent(".rebuild-in-progress.wav"))
        return nil
    }
    removeInTwoHalves(model.store, letting: gate)
    model.requestSourceRebuild(id: id)
    try #require(model.pendingSourceRebuild != nil, "the precondition: Rebuild Audio is offered for this meeting")
    let rebuild = try #require(model.performSourceRebuild(confirmed: true))
    try await waitUntilEntered(gate)

    model.deleteMeetings(ids: [id])

    let listed = model.store.meeting(id: id) != nil
    #expect(!listed || FileManager.default.fileExists(atPath: wav.path),
            "the delete half-completed: the meeting is listed again without its audio")
    #expect(listed, "a delete while Rebuild Audio holds the meeting's folder is refused, not raced")

    gate.release()
    await rebuild.value
    model.deleteMeetings(ids: [id])
    #expect(model.store.meeting(id: id) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@MainActor
@Test("A delete during the launch notes.md backfill completes, and the backfill writes nothing into the going folder (F870, F867)")
func deleteDuringNotesBackfillIsNeverHalfDone() async throws {
    let (model, id, folder, root) = try makeModel("backfill")
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = folder.appendingPathComponent("meeting.wav")
    let store = model.store
    // Stale, so the pass has something to write.
    try Data("an old composition".utf8).write(to: folder.appendingPathComponent("notes.md"))
    let gate = WriterGate()
    let writers = store.folderWriters
    store.notesBackfillPass = { snapshot, root in
        gate.enter()
        defer { gate.land() }
        guard gate.block(until: { $0.isReleased }) else { Issue.record("the backfill was never let go"); return 0 }
        return await MeetingStore.runNotesBackfillPass(snapshot, root: root, writers: writers)
    }
    removeInTwoHalves(store, letting: gate)
    let backfill = Task { @MainActor in await store.backfillNotesSidecars() }
    try await waitUntilEntered(gate)

    store.delete(ids: [id])

    let listed = store.meeting(id: id) != nil
    #expect(!listed || FileManager.default.fileExists(atPath: wav.path),
            "the delete half-completed: the meeting is listed again without its audio")
    // The pass had not started this meeting, so the delete claimed it and the pass skipped it.
    #expect(!listed)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    gate.release()
    await backfill.value
    #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing recreated the folder")
}

@MainActor
@Test("A meeting the backfill is writing is refused by a delete, and one it is not is deleted (F870)")
func folderWritersRefuseOnlyTheHeldMeeting() throws {
    let (model, id, folder, root) = try makeModel("held")
    defer { try? FileManager.default.removeItem(at: root) }
    let other = UUID()
    let otherFolder = root.appendingPathComponent("Recordings/\(other.uuidString)", isDirectory: true)
    try writeCapture(in: otherFolder)
    model.store.upsert(MeetingRecord(
        id: other, title: "Standup", duration: 60, recordingPath: "Recordings/\(other.uuidString)/meeting.wav",
        status: .completed, transcriptText: "Hi."
    ))
    try #require(model.store.folderWriters.begin(id))

    let removed = model.store.delete(ids: [id, other])

    #expect(removed == [other])
    #expect(model.store.meeting(id: id) != nil)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.wav").path))
    #expect(!FileManager.default.fileExists(atPath: otherFolder.path))
    #expect(model.store.storageErrorMessage == MeetingStore.busyFolderDeleteMessage(["Weekly sync"]))

    model.store.folderWriters.end(id)
    #expect(model.store.delete(ids: [id]) == [id])
    // A writer arriving while a delete holds the meeting is turned away (the backfill's side).
    #expect(model.store.folderWriters.claimForDeletion([other]).held.isEmpty)
    #expect(!model.store.folderWriters.begin(other))
    model.store.folderWriters.endDeletion([other])
    #expect(model.store.folderWriters.begin(other))
}
