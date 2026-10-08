import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F831 — the corrections review's Apply (Correct Toward Vocabulary, Apply Rules and Correct with
// Local AI all end there) rewrote the lines and the timestamped text and registered nothing, unlike
// Delete Line and Remove Lines (F423). One wrong tick was permanent except by retyping it. The undo
// follows F423's shape: the exact before-state comes back, and only while the transcript is still
// exactly as the Apply left it.

@MainActor
private func makeModel() throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F831-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Standup", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    return (model, id, root)
}

/// Scored, so "exactly" covers the metrics a rebuilt segment could drop.
private let lines = [
    TranscriptSegment(speaker: nil, start: 0, end: 4.2, text: "The Kestrol rollout starts Monday.", avgLogprob: -0.31, noSpeechProb: 0.02, compressionRatio: 1.4),
    TranscriptSegment(speaker: nil, start: 4.2, end: 9.8, text: "Ask Dana about the Kestrol budget.", avgLogprob: -0.44, noSpeechProb: 0.01, compressionRatio: 1.3),
    TranscriptSegment(speaker: nil, start: 9.8, end: 12.5, text: "That's all.", avgLogprob: -0.12, noSpeechProb: 0.03, compressionRatio: 1.1),
]

private let corrections = [
    GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
    GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel"),
]

@MainActor
@Test("Undo puts back exactly the lines and text an Apply of reviewed corrections replaced (F831)")
func appliedCorrectionsUndoExactly() throws {
    let (model, id, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try #require(model.store.meeting(id: id))

    let applied = try #require(model.applyGlossaryCorrections(corrections, to: id))
    let after = try #require(model.store.meeting(id: id))
    try #require(after.segments.map(\.text) == ["The Kestrel rollout starts Monday.", "Ask Dana about the Kestrel budget.", "That's all."],
                 "the precondition: the Apply changed the transcript")

    #expect(model.undoTranscriptCorrections(applied))
    let undone = try #require(model.store.meeting(id: id))
    #expect(undone.segments == before.segments)
    #expect(undone.transcriptText == before.transcriptText)
    #expect(!model.store.isTranscriptEdited(undone), "the undone transcript is the rendering of its lines again")
    // Done once: the same undo a second time finds the transcript no longer as the Apply left it.
    #expect(!model.undoTranscriptCorrections(applied))
}

@MainActor
@Test("Undo of an Apply is refused once the transcript changed since, and the later change stands (F831)")
func correctionUndoIsRefusedAfterALaterChange() throws {
    // A hand edit made after the Apply.
    do {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let applied = try #require(model.applyGlossaryCorrections(corrections, to: id))
        let edited = (model.store.meeting(id: id)?.transcriptText ?? "") + "\nMy own note."
        model.store.editTranscript(id: id, text: edited)

        #expect(!model.undoTranscriptCorrections(applied))
        #expect(model.store.meeting(id: id)?.transcriptText == edited)
        #expect(model.store.meeting(id: id)?.segments == applied.segmentsAfter)
    }
    // A line deleted after the Apply.
    do {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let applied = try #require(model.applyGlossaryCorrections(corrections, to: id))
        try #require(model.removeTranscriptLines(at: IndexSet(integer: 2), from: id) != nil)

        #expect(!model.undoTranscriptCorrections(applied))
        #expect(model.store.meeting(id: id)?.segments == Array(applied.segmentsAfter.prefix(2)))
    }
}

@MainActor
@Test("An Apply that changes nothing, or is refused, leaves nothing to undo (F831)")
func applyThatChangesNothingHasNoUndo() throws {
    let (model, id, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(model.applyGlossaryCorrections([], to: id) == nil)
    #expect(model.applyGlossaryCorrections([GlossaryCorrection(segmentIndex: 2, from: "Kestrol", to: "Kestrel")], to: id) == nil,
            "a correction whose text is not in its line changes nothing")
    #expect(model.store.meeting(id: id)?.segments == lines)

    model.store.editTranscript(id: id, text: "Rewritten by hand.")
    #expect(model.applyGlossaryCorrections(corrections, to: id) == nil, "a hand-edited transcript is refused, as before")
    #expect(model.store.meeting(id: id)?.transcriptText == "Rewritten by hand.")
}

// The Apply lives in `ContentView`'s review sheet, which this target cannot render (F174's standing
// reason). Comments are stripped first, so an explanation cannot stand in for the wiring (F285).
@Test("The review sheet's Apply registers Edit ▸ Undo, which reaches the model's undo (F831)")
func correctionsApplyRegistersUndo() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("guard let applied = model.applyGlossaryCorrections(accepted, to: meetingID) else { return }"))
    #expect(source.contains("registerCorrectionUndo(applied, model: model, undoManager: undoManager)"))
    #expect(source.contains("model.undoTranscriptCorrections(applied)"))
}
