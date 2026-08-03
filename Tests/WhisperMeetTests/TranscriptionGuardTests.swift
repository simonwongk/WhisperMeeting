import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TxGuard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "TxGuard.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

// F144 — apply(result:) must never lose the fuller text when the segments don't reconstruct it.
@MainActor
@Test("apply(result:) keeps the full text when segments don't cover it (F144)")
func applyPreservesFullTextOnUnderCoveringSegments() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .processing))

    // Segments cover only the first two words of a longer text.
    let result = TranscriptionResult(
        id: "x", text: "one two three four five", languageCode: "en",
        audioDuration: 5, confidence: nil, segments: [seg("one two", 0, 1)]
    )
    model.apply(result: result, to: id)

    let stored = model.store.meeting(id: id)
    #expect(stored?.transcriptText.contains("three four five") == true) // nothing dropped
    #expect(stored?.segments.isEmpty == true)                           // incomplete segments dropped for consistency
}

// F144 — the normal case (segments reconstruct the text) still renders timestamped segments.
@MainActor
@Test("apply(result:) keeps timestamped segments when they cover the text (F144)")
func applyKeepsSegmentsWhenTheyCoverText() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .processing))
    let segments = [seg("one two", 0, 1), seg("three four", 1, 2)]
    let result = TranscriptionResult(
        id: "x", text: "one two three four", languageCode: "en",
        audioDuration: 2, confidence: nil, segments: segments
    )
    model.apply(result: result, to: id)
    #expect(model.store.meeting(id: id)?.segments.count == 2)
}

// F140 — a normal transcription must refuse to start while an auxiliary (second-opinion/segment-rerun)
// engine run is active.
@MainActor
@Test("beginTranscription refuses while an auxiliary engine run is active (F140)")
func beginTranscriptionRefusesDuringAuxiliaryRun() async throws {
    let model = try makeModel()
    let id1 = UUID()
    model.store.upsert(MeetingRecord(
        id: id1, title: "A", recordingPath: "Recordings/\(id1.uuidString)/meeting.wav",
        status: .completed, transcriptText: "hello", segments: [seg("hello", 0, 1)]
    ))
    let id2 = UUID()
    model.store.upsert(MeetingRecord(id: id2, title: "B", status: .recorded))

    // The auxiliary engine override returns immediately; the aux Task is scheduled but — on the single
    // MainActor — cannot run until this synchronous stretch suspends, so isRunningAuxiliaryEngine stays
    // true across the beginTranscription call below.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hello", 0, 1)])
    }
    model.requestSecondOpinion(id: id1)
    #expect(model.isRunningAuxiliaryEngine == true)

    model.beginTranscription(id: id2)
    #expect(model.alertMessage != nil)                 // rejected with guidance
    #expect(model.hasActiveTranscription == false)     // id2 not enqueued

    // Drain the auxiliary run.
    while model.isRunningAuxiliaryEngine { await Task.yield() }
}
