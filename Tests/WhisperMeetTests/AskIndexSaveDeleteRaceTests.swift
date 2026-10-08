import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F849 — F538 moved the meaning index's per-group saves off the main actor. `MeetingStore.delete`
// runs on the main actor and removes a meeting's folder the way FileManager does, contents first and
// the folder last; a save landing between the two puts files back into a folder that is about to be
// removed, the final `rmdir` fails, and F146's rollback lists the meeting again — after its audio was
// already removed. The window is milliseconds, so this test holds it open with two seams: the save,
// which — when it runs off the main thread, where it can overlap a delete — waits for the removal to
// have emptied the folder, and the removal, which lets the save land before taking the folder itself
// away. The fix saves on the main actor again, where the save runs wholly before the delete.

/// Where the save is, written from whichever thread each seam runs on.
private final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var landed = false

    var hasEntered: Bool { lock.withLock { entered } }
    var hasLanded: Bool { lock.withLock { landed } }
    func enter() { lock.withLock { entered = true } }
    func release() { lock.withLock { released = true } }
    func land() { lock.withLock { landed = true } }

    /// A bounded poll on this gate's own state, blocking the calling thread. Large, because the
    /// subject is an ordering, not a speed; false only if the other side never arrived.
    func block(until condition: (SaveGate) -> Bool, seconds: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(self) {
            guard Date() < deadline else { return false }
            usleep(1_000)
        }
        return true
    }
    var isReleased: Bool { lock.withLock { released } }
}

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F849-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.isAskEmbeddingModelInstalled = { true }
    model.refreshRuntime()
    return (model, root)
}

@MainActor
@Test("A meaning-index save cannot land inside a delete of the same meeting, so the delete never half-completes (F849)")
func indexSaveNeverLandsInsideADelete() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let lines = [TranscriptSegment(speaker: nil, start: 0, end: 5, text: "Pricing for the first customer.")]
    model.store.upsert(MeetingRecord(
        id: id, title: "Pricing", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    let folder = model.store.recordingDirectoryURL(for: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appendingPathComponent("meeting.wav")
    try Data("audio".utf8).write(to: wav)

    model.askEmbedder = { texts, _ in (2, texts.flatMap { _ in [Float(1), 0] }) }
    let gate = SaveGate()
    model.askIndexSave = { index, directory in
        gate.enter()
        defer { gate.land() }
        // A save on the main thread cannot run inside a delete, which runs there too, so there is
        // nothing to hold it for — and holding it would block the test that has to start the delete.
        if !Thread.isMainThread {
            guard gate.block(until: { $0.isReleased }) else {
                Issue.record("the delete never reached its removal")
                return
            }
        }
        try index.write(to: directory)
    }
    model.store.removeRecordingDirectory = { directory in
        // FileManager's recursive removal, in its two halves: the contents it listed, then the folder.
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
        // Between the halves, the save in flight lands — if one can be in flight.
        gate.release()
        if gate.hasEntered, !gate.block(until: { $0.hasLanded }) {
            Issue.record("the save never landed")
        }
        guard rmdir(directory.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
    }

    let search = Task { @MainActor in
        _ = await model.askMeetingsByMeaning(query: "pricing", scope: MeetingScope())
    }
    // Wait for the save to begin, on whichever thread it runs.
    let deadline = Date().addingTimeInterval(60)
    while !gate.hasEntered, Date() < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try #require(gate.hasEntered, "the search never reached its save")

    model.deleteMeetings(ids: [id])
    await search.value

    // The delete was asked for and nothing refused it, so it completes: no row, no folder. Before
    // the fix the row came back and its audio did not.
    #expect(model.store.meeting(id: id) == nil, "the delete half-completed and listed the meeting again")
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    // Whatever the outcome, a listed meeting keeps its recording.
    if model.store.meeting(id: id) != nil {
        #expect(FileManager.default.fileExists(atPath: wav.path), "the meeting is listed again without its audio")
    }
}
