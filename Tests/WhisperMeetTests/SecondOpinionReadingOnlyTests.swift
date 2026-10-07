import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F658 — Second Opinion's Replace swaps the whole line for the row's joined reading. Where that
// reading carries a neighbouring line's words, or leaves some of this line's out, the row now shows it
// without Replace, and the model refuses a Replace of it from any caller.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
@Test("A row whose reading carries a neighbour's words is shown, and Replace of it writes nothing (F658)")
func readingOnlyRowIsNeverWritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F658-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F658.\(UUID().uuidString)")!)
    let id = UUID()
    let stored = [seg("We ship on Friday.", 10, 15), seg("Yeah, sure.", 15, 15.8)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored), segments: stored
    ))
    // The other engine started "Yeah sure." 0.4 s early, so F572 joined it into the first line's row.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "We will ship on Friday. Yeah sure.", languageCode: "en", audioDuration: 16,
                            confidence: nil, segments: [seg("We will ship on Friday.", 10.1, 14.6), seg("Yeah sure.", 14.6, 15.4)])
    }

    await model.computeSecondOpinion(id: id)
    let row = try #require(model.secondOpinionSpans?.first)
    #expect(row.kind == .diverge)
    #expect(row.secondaryText == "We will ship on Friday. Yeah sure.", "the reading is still shown")
    #expect(!row.offersReplacement)

    #expect(model.applySecondOpinionSpan(row, to: id) == .refused(AppModel.secondOpinionReadingOnly))
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.segments == stored, "Replace would have written \"Yeah sure.\" into this line as well as the next")
    #expect(meeting.transcriptText == TranscriptFormatter.timestamped(stored))
}

// The sheet lives in `ContentView`, which this target cannot render (F174's standing reason).
// Comments are stripped first, so an explanation cannot stand in for the wiring (F285).
@Test("The Second Opinion sheet offers Replace only where the row allows it, and says why not (F658)")
func sheetGatesReplaceOnTheRow() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("if span.kind == .diverge, span.secondaryText != nil, span.offersReplacement {"))
    #expect(source.contains("if !span.offersReplacement {"))
    #expect(source.contains("Text(AppModel.secondOpinionReadingOnly)"))
}
