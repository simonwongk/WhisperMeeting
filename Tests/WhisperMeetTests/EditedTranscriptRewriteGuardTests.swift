import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F436 — "Re-transcribe this segment" and Second Opinion's Replace both finish by rebuilding
// `transcriptText` from the segments. A manual edit changes only `transcriptText`, so on a
// hand-edited transcript that rebuild replaces every edit the user made with the original lines.
// Every other tool that rewrites the text from its lines refuses an edited transcript
// (`applyGlossaryCorrections`, the line removals, Correct with Local AI); these two did not, and the
// Read view — where the re-run lives — is shown for edited transcripts, with a note saying "your
// edits are in Edit view".
//
// The re-run is minutes of engine time, so it is also checked again at the write: an edit made
// while the engine ran must win over the text the engine brings back.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class EngineCall: @unchecked Sendable {
    var ran = false
}

/// A model with one completed meeting over two seconds of silent 16 kHz mono audio.
@MainActor
private func makeMeeting(segments: [TranscriptSegment]) throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F436-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var wav = WAVWriter.header(sampleRate: 16_000, dataByteCount: 96_000)
    wav.append(Data(count: 96_000))
    try wav.write(to: dir.appendingPathComponent("meeting.wav"))
    let defaults = UserDefaults(suiteName: "F436.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    return (model, id, root)
}

private let lines = [seg("Hello Jon", 0, 1), seg("second wrong", 1, 2), seg("third", 2, 3)]
private let handEdited = "00:00  Hello John — names fixed by hand\n00:01  second wrong\n00:02  third\nMy note."

@MainActor
@Test("Re-transcribing a segment of a hand-edited transcript is refused and the edits survive (F436)")
func segmentReRunRefusesAHandEditedTranscript() async throws {
    let (model, id, root) = try makeMeeting(segments: lines)
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.editTranscript(id: id, text: handEdited)
    let call = EngineCall()
    model.runTranscriptionEngineOverride = { _, _ in
        call.ran = true
        return TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                                   confidence: nil, segments: [seg("second right", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.transcriptText == handEdited)
    #expect(meeting.segments == lines)
    #expect(call.ran == false, "no engine time is spent on a result that could not be written")
    #expect(model.alertMessage == AppModel.segmentReRunRefusedForEdits)
}

@MainActor
@Test("The context-menu request refuses up front, before it claims the engine (F436)")
func segmentReRunRequestRefusesAHandEditedTranscript() throws {
    let (model, id, root) = try makeMeeting(segments: lines)
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.editTranscript(id: id, text: handEdited)
    // Stubbed so a regression that lets the request through cannot reach a real installed engine.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                            confidence: nil, segments: [seg("second right", 0, 1)])
    }

    model.requestSegmentReTranscription(id: id, index: 1)

    // Synchronous: the refusal is immediate, so nothing was started that a later check could miss.
    #expect(model.isRunningAuxiliaryEngine == false)
    #expect(model.alertMessage == AppModel.segmentReRunRefusedForEdits)
}

@MainActor
@Test("An edit made while the engine ran wins over the re-run's result (F436)")
func segmentReRunKeepsAnEditMadeWhileItRan() async throws {
    let (model, id, root) = try makeMeeting(segments: lines)
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        // The user fixes a name in Edit view while the engine is still working.
        await MainActor.run { model.store.editTranscript(id: id, text: handEdited) }
        return TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                                   confidence: nil, segments: [seg("second right", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.transcriptText == handEdited)
    #expect(meeting.segments == lines, "text and lines stay the pair the edit was made against")
    #expect(model.alertMessage == AppModel.segmentReRunDiscardedForEdits)
}

@MainActor
@Test("Second Opinion's Replace is refused on a hand-edited transcript and the edits survive (F436)")
func secondOpinionReplaceRefusesAHandEditedTranscript() async throws {
    let (model, id, root) = try makeMeeting(segments: lines)
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "Hello Jon second right third", languageCode: "en", audioDuration: 3,
                            confidence: nil, segments: [seg("Hello Jon", 0, 1), seg("second right", 1, 2), seg("third", 2, 3)])
    }
    await model.computeSecondOpinion(id: id)
    let diverging = try #require(model.secondOpinionSpans?.first { $0.kind == .diverge })
    // The comparison was made; then the user edited before pressing Replace.
    model.store.editTranscript(id: id, text: handEdited)

    model.applySecondOpinionSpan(diverging, to: id)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.transcriptText == handEdited)
    #expect(meeting.segments == lines)
    #expect(model.alertMessage == AppModel.secondOpinionReplaceRefusedForEdits)
}

@MainActor
@Test("Replace still works on an unedited transcript (F436 control)")
func secondOpinionReplaceStillAppliesToAnUneditedTranscript() async throws {
    let (model, id, root) = try makeMeeting(segments: lines)
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "Hello Jon second right third", languageCode: "en", audioDuration: 3,
                            confidence: nil, segments: [seg("Hello Jon", 0, 1), seg("second right", 1, 2), seg("third", 2, 3)])
    }
    await model.computeSecondOpinion(id: id)
    let diverging = try #require(model.secondOpinionSpans?.first { $0.kind == .diverge })

    model.applySecondOpinionSpan(diverging, to: id)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.segments[1].text == "second right")
    #expect(model.store.isTranscriptEdited(meeting) == false)
    #expect(model.alertMessage == nil)
}

// The Read view's context menu cannot be rendered here (F174's standing reason), so its gate is
// checked in the source, comments stripped first (F285). The item is greyed on an edited transcript
// and the reason sits in the same menu, beside the items it explains.
@Test("The segment context menu greys Re-transcribe on an edited transcript and says why (F436)")
func segmentContextMenuIsGatedOnEdits() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("model.requestSegmentReTranscription(id: meetingID, index: index)"))
    #expect(source.contains(".disabled(isEdited || model.hasActiveTranscription || model.isRunningAuxiliaryEngine)"))
    #expect(source.contains("Text(AppModel.editedTranscriptReason)"))
}
