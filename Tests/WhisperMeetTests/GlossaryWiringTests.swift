import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F82 — the GlossaryCorrector core (delivers F65) shipped tested but unreachable. Wiring adds two
// AppModel methods so the meeting-detail transcript toolbar can compute proposals and apply the
// user-accepted ones. This drives the app-level calls over a temp store and asserts the transcript
// is corrected while the recording is never touched.
@MainActor
@Test("Glossary corrections compute and apply through AppModel without touching audio (F82)")
func glossaryCorrectionsApplyThroughAppModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlossaryWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F82.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "we deployed cooper netties today"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "and it worked"),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id,
        title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    ))
    model.store.addVocabulary(["Kubernetes"])

    let proposals = model.glossaryCorrections(for: id)
    #expect(proposals.contains { $0.to == "Kubernetes" && $0.segmentIndex == 0 })

    model.applyGlossaryCorrections(proposals, to: id)
    let updated = model.store.meeting(id: id)
    #expect(updated?.segments[0].text.contains("Kubernetes") == true)
    #expect(updated?.segments[1].text == "and it worked")   // untouched
    #expect(updated?.transcriptText == TranscriptFormatter.timestamped(updated!.segments))

    // A text-only correction never creates or opens the recording.
    #expect(!FileManager.default.fileExists(atPath: model.store.recordingURL(for: updated!).path))
}
