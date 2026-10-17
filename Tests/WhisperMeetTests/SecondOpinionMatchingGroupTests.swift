import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F869 — the user's decision (2026-10-16): "Show matching groups as agreeing". Through the app's own
// Second Opinion run: a Qwen meeting whose lines Whisper heard as one, word for word (F872's real pair),
// comes back with every row agreeing, so the sheet lists no difference for them and offers no Replace.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
@Test("Second Opinion shows lines the other engine split differently, saying the same words, as agreeing (F869)")
func secondOpinionShowsAMatchingGroupAsAgreeing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F869-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())))
    let id = UUID()
    let lines = [seg("Good morning, everyone.", 0.0, 1.2),
                 seg("Let's get started with the weekly planning meeting.", 1.36, 3.84),
                 seg("Let's put the order into day then.", 54.88, 56.72)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(lines), segments: lines, transcriptionEngine: .qwenBalanced
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "w", text: "", languageCode: "en", audioDuration: 57, confidence: nil, segments: [
            seg("Good morning everyone, let's get started with the weekly planning meeting.", 0.0, 3.76),
            seg("Let's put the order in today then.", 54.62, 56.74),
        ])
    }

    await model.computeSecondOpinion(id: id)

    let spans = try #require(model.secondOpinionSpans)
    #expect(spans.map(\.kind) == [.agree, .agree, .diverge], "\(spans.map(\.kind))")
    #expect(spans.last?.offersReplacement == true, "the real difference keeps its Replace")
}
