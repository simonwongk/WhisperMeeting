import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F165 — on-device transcript correction. Drives the AppModel wiring: the vocabulary + transcript
// reach the correction seam, results map to reviewable GlossaryCorrections (the same F82 review/apply
// path), and the install-required fallback fires instead of silently doing nothing.

private final class CaptureBox: @unchecked Sendable {
    var transcript: String?
    var vocabulary: [String]?
    var reference: String??
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CorrectionWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F165.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Local correction threads vocab+transcript through the seam and maps to reviewable corrections (F165)")
func localCorrectionProposesReviewableCorrections() async throws {
    let model = try makeModel()
    model.isCorrectionModelInstalled = { true }
    let box = CaptureBox()
    model.proposeTranscriptCorrections = { transcript, vocabulary, reference in
        box.transcript = transcript
        box.vocabulary = vocabulary
        box.reference = reference
        return [TranscriptCorrection(from: "Kew Bernetes", to: "Kubernetes")]
    }

    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Kew Bernetes runs the cluster")]
    let id = UUID()
    model.store.addVocabulary(["Kubernetes"])
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = await model.proposeLocalCorrections(for: id)

    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Kew Bernetes", to: "Kubernetes")])
    #expect(box.vocabulary == ["Kubernetes"])
    #expect(box.transcript?.contains("Kew Bernetes runs the cluster") == true)
    #expect(model.alertMessage == nil)
    #expect(model.isProposingCorrections == false) // flag cleared after the run
}

@MainActor
@Test("Local correction offers install when the correction helper is missing (F165)")
func localCorrectionRequiresInstalledHelper() async throws {
    let model = try makeModel()
    model.isCorrectionModelInstalled = { false }
    let box = CaptureBox()
    model.proposeTranscriptCorrections = { _, _, _ in box.transcript = "ran"; return [] }

    let id = UUID()
    model.store.addVocabulary(["Kubernetes"])
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed, transcriptText: "hello", segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello")
        ]
    ))

    let proposals = await model.proposeLocalCorrections(for: id)

    #expect(proposals.isEmpty)
    #expect(box.transcript == nil) // the model was never invoked
    #expect(model.alertMessage?.contains("Install or update the local model") == true)
}
