import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

// F88 UX fix — the "running" state must be scoped to the meeting actually being processed, so only that
// meeting's button shows a spinner (not every meeting's, via a global flag).
@MainActor
@Test("Second opinion running state is scoped to the specific meeting (F88 UX)")
func secondOpinionRunningStateIsScopedToMeeting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecondOpScope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F88scope.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let id1 = UUID(), id2 = UUID()
    for id in [id1, id2] {
        model.store.upsert(MeetingRecord(
            id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: "hi", segments: [seg("hi", 0, 1)], transcriptionEngine: .whisperLarge
        ))
    }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hi", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hi", 0, 1)])
    }

    model.requestSecondOpinion(id: id1)
    #expect(model.secondOpinionRunningID == id1)   // only meeting 1 is "running"
    #expect(model.secondOpinionRunningID != id2)   // meeting 2 is NOT shown as running

    while model.isRunningAuxiliaryEngine { await Task.yield() }
    #expect(model.secondOpinionRunningID == nil)   // cleared when done
}
