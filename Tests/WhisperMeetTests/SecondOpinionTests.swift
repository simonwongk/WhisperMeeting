import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecondOpinion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F88.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
}

// F88 — a "second opinion" runs the OTHER engine on the same recording and compares, but must never
// overwrite the stored transcript; only an explicit per-span apply changes it.
@MainActor
@Test("Second opinion compares the other engine and leaves the stored transcript byte-for-byte intact (F88)")
func secondOpinionDoesNotMutateStoredTranscript() async throws {
    let (model, _) = try makeModel()
    let id = UUID()
    let stored = [seg("hello world", 0, 1), seg("second segment", 1, 2)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored),
        segments: stored
    ))
    let before = model.store.meeting(id: id)?.transcriptText

    // The injected "other engine" disagrees on the second segment.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(
            id: "x", text: "hello world second thing", languageCode: "en",
            audioDuration: 2, confidence: nil,
            segments: [seg("hello world", 0, 1), seg("second thing", 1, 2)]
        )
    }

    await model.computeSecondOpinion(id: id)

    #expect(model.secondOpinionSpans?.count == 2)
    #expect(model.secondOpinionSpans?.contains { $0.kind == .agree } == true)      // first segment
    #expect(model.secondOpinionSpans?.contains { $0.kind == .diverge } == true)    // second segment
    #expect(model.store.meeting(id: id)?.transcriptText == before)                 // never overwritten

    // Applying one span replaces only that segment's text, on explicit user action.
    if let diverge = model.secondOpinionSpans?.first(where: { $0.kind == .diverge }) {
        model.applySecondOpinionSpan(diverge, to: id)
    }
    #expect(model.store.meeting(id: id)?.segments[1].text == "second thing")
    #expect(model.store.meeting(id: id)?.segments[0].text == "hello world")        // untouched
}
