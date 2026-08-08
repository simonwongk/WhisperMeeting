import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F185 — queue every ready meeting in one action. After a bulk import, pressing Transcribe once per
// meeting is tedious; this must still go through the normal per-meeting path so the queue applies.

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchTranscribeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F185.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
}

@MainActor
@Test("Only meetings with audio and no transcript count as ready to transcribe (F185)")
func readyMeetingsExcludeCompletedAndAudioless() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }

    let ready = UUID(), done = UUID(), noAudio = UUID()
    model.store.upsert(MeetingRecord(id: ready, title: "A", recordingPath: "Recordings/a/recording.wav", status: .recorded))
    model.store.upsert(MeetingRecord(id: done, title: "B", recordingPath: "Recordings/b/recording.wav", status: .completed))
    model.store.upsert(MeetingRecord(id: noAudio, title: "C", recordingPath: "", status: .recorded))

    let ids = model.readyToTranscribeMeetings.map(\.id)
    #expect(ids == [ready])
}

@MainActor
@Test("Queueing all ready meetings enqueues each one, not just the first (F185)")
func queuesEveryReadyMeeting() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // Engine install guard is checked inside beginTranscription; stub it so the queue is reached.
    model.isSummarizerModelInstalled = { true }

    for index in 0..<3 {
        model.store.upsert(MeetingRecord(
            title: "M\(index)", recordingPath: "Recordings/\(index)/recording.wav", status: .recorded
        ))
    }
    #expect(model.readyToTranscribeMeetings.count == 3)
    // Returns how many it attempted, so the caller/UI can report honestly.
    #expect(model.beginTranscriptionForAllReady() == 3)
}
