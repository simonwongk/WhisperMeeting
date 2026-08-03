import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecondOpFail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F142.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

// F142 — when the other engine fails to launch, the sheet must show a failure, not read as "no differences".
@MainActor
@Test("Second opinion sets a failed state (not empty spans) when the engine errors (F142)")
func secondOpinionSignalsFailure() async throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "hello", segments: [seg("hello", 0, 1)]
    ))
    struct EngineDown: Error {}
    model.runTranscriptionEngineOverride = { _, _ in throw EngineDown() }

    await model.computeSecondOpinion(id: id)

    #expect(model.secondOpinionFailed == true)   // distinct failure state
    #expect(model.secondOpinionSpans == nil)     // never rendered as "no differences"
}

// F142 — the second opinion runs the engine that did NOT produce the meeting, even if current Settings
// were changed to match the meeting's engine.
@MainActor
@Test("Second opinion runs the genuine other engine using the meeting's recorded engine (F142)")
func secondOpinionUsesMeetingEngineSnapshot() async throws {
    let model = try makeModel()
    let id = UUID()
    // The meeting was transcribed with Whisper Large; record that on the meeting.
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "hello", segments: [seg("hello", 0, 1)],
        transcriptionEngine: .whisperLarge
    ))
    model.selectedEngine = .whisperLarge // current Settings happen to match the meeting's engine

    let box = EngineBox()
    model.runTranscriptionEngineOverride = { selection, _ in
        box.engine = selection.engine
        return TranscriptionResult(id: "x", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hello", 0, 1)])
    }
    await model.computeSecondOpinion(id: id)

    #expect(box.engine == .qwenBalanced) // the OTHER engine, not a re-run of Whisper
}

private final class EngineBox: @unchecked Sendable { var engine: MeetingTranscriptionEngine? }
