import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F874 — Second Opinion, Correct Toward Vocabulary and Apply Replacement Rules propose against the
// stored lines. On a hand-edited (or cleared) transcript those lines no longer describe what is shown,
// and only the Improve menu's `.disabled(isEdited …)` kept these model methods from running there;
// Correct with Local AI already refused inside the method. A caller that bypasses the menu — a future
// entry point, a shortcut — would have listed the original lines in a proposal sheet. Each now refuses
// itself, before any engine or pass runs, with the menu's own reason.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var ran: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private let lines = [seg("Hello Jon", 0, 1), seg("second line", 1, 2)]
private let handEdited = "00:00  Hello John — fixed by hand\n00:01  second line"

/// A model with one completed, hand-edited meeting over two seconds of silent 16 kHz audio, a
/// vocabulary term and a replacement rule, so every proposer has something it could propose.
@MainActor
private func editedMeeting() throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F874-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var wav = WAVWriter.header(sampleRate: 16_000, dataByteCount: 64_000)
    wav.append(Data(count: 64_000))
    try wav.write(to: dir.appendingPathComponent("meeting.wav"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    model.store.editTranscript(id: id, text: handEdited)
    #expect(model.store.isTranscriptEdited(try #require(model.store.meeting(id: id))), "precondition: the transcript reads as edited")
    return (model, id, root)
}

@MainActor
@Test("Second Opinion refuses a hand-edited transcript itself, before any engine runs (F874)")
func secondOpinionRefusesAnEditedTranscript() async throws {
    let (model, id, root) = try editedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = Ran()
    model.runTranscriptionEngineOverride = { _, _ in
        engine.mark()
        return TranscriptionResult(id: "x", text: "Hello John", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [seg("Hello John", 0, 1)])
    }

    #expect(model.requestSecondOpinion(id: id) == false, "the request started a run")
    #expect(model.alertMessage == AppModel.improveToolRefusedForEdits)
    #expect(!model.isRunningAuxiliaryEngine)

    // The worker, reached directly, refuses too, and says why in the sheet's own words.
    await model.computeSecondOpinion(id: id)
    #expect(engine.ran == false, "an engine ran for a transcript whose lines no longer describe it")
    #expect(model.secondOpinionSpans == nil)
    #expect(model.secondOpinionFailed)
    #expect(model.secondOpinionFailureReason == AppModel.improveToolRefusedForEdits)
}

@MainActor
@Test("Correct Toward Vocabulary refuses a hand-edited transcript itself, before its pass runs (F874)")
func vocabularyCorrectionRefusesAnEditedTranscript() async throws {
    let (model, id, root) = try editedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    let pass = Ran()
    model.glossaryCorrectionPass = { _, _, _ in
        pass.mark()
        return [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "John")]
    }

    let proposals = await model.proposeGlossaryCorrections(for: id)

    #expect(proposals == nil)
    #expect(pass.ran == false)
    #expect(model.alertMessage == AppModel.improveToolRefusedForEdits)
}

@MainActor
@Test("Apply Replacement Rules refuses a hand-edited transcript itself, before its pass runs (F874)")
func replacementRulesRefuseAnEditedTranscript() async throws {
    let (model, id, root) = try editedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    let pass = Ran()
    model.replacementRulePass = { _ in
        pass.mark()
        return [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "John")]
    }

    let proposals = await model.replacementRuleCorrections(for: id)

    #expect(proposals == nil)
    #expect(pass.ran == false)
    #expect(model.alertMessage == AppModel.improveToolRefusedForEdits)
}
