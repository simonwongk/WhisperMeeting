import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1059 — F1028 made a transcription wait while Shrink works on its meeting. Second Opinion, a segment re-run and
// speaker analysis read the recording Shrink replaces, and Rebuild Audio writes in the folder Shrink writes in
// (`folderWriters` refuses only a delete), and none of them asked. Each now refuses while Shrink runs on that
// meeting. And Shrink, which refused the other three while they ran, did not refuse a running second opinion.

@MainActor
private func modelWithAMeeting(_ label: String) throws -> (AppModel, URL, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1059-\(label)-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000 * 4), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))
    // No engine: a second opinion this file starts must never reach a real runtime (F991).
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!,
                         whisperExecutable: { nil }, qwenInstalled: { false })
    model.trashForShrink = try ShrinkTestTrash(in: root).seam
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "Hello there."),
                    TranscriptSegment(speaker: nil, start: 2, end: 4, text: "General Kenobi.")]
    model.store.upsert(MeetingRecord(
        id: id, title: "Weekly sync", duration: 4, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments))
    return (model, root, id)
}

@MainActor
@Test("While Shrink works on a meeting, Second Opinion, a segment re-run, speaker analysis and Rebuild Audio each refuse (F1059)")
func auxiliaryActionsRefuseWhileShrinkRuns() async throws {
    let (model, root, id) = try modelWithAMeeting("refuse")
    defer { try? FileManager.default.removeItem(at: root) }
    model.shrinkRunningID = id

    #expect(!model.requestSecondOpinion(id: id))
    #expect(model.alertMessage?.contains("being shrunk") == true, "\(model.alertMessage ?? "nothing said")")
    #expect(model.secondOpinionRunningID == nil)

    model.alertMessage = nil
    model.requestSegmentReTranscription(id: id, index: 0)
    #expect(model.alertMessage?.contains("being shrunk") == true, "\(model.alertMessage ?? "nothing said")")
    #expect(model.segmentReTranscriptionRunningID == nil)

    model.alertMessage = nil
    model.requestSpeakerDiarization(for: id)
    #expect(model.alertMessage?.contains("being shrunk") == true, "\(model.alertMessage ?? "nothing said")")
    #expect(model.diarizationRunningID == nil)

    model.alertMessage = nil
    model.requestSourceRebuild(id: id)
    #expect(model.alertMessage?.contains("being shrunk") == true, "\(model.alertMessage ?? "nothing said")")
    #expect(model.sourceRebuildRunningID == nil)

    // Another meeting's Shrink stops none of them on this one.
    model.shrinkRunningID = UUID()
    model.alertMessage = nil
    #expect(model.refusalWhileShrinking(id, "Speaker analysis") == nil)
}

@MainActor
@Test("Shrink waits for a second opinion running on the meeting, as it waits for the other three (F1059)")
func shrinkRefusesWhileASecondOpinionRuns() async throws {
    let (model, root, id) = try modelWithAMeeting("reverse")
    defer { try? FileManager.default.removeItem(at: root) }
    await model.refreshStorage(ids: [id])
    let meeting = try #require(model.store.meeting(id: id))
    #expect(model.shrinkUnavailability(for: meeting) == nil, "fixture: the meeting cannot be shrunk to begin with")
    try #require(model.requestSecondOpinion(id: id), "fixture: \(model.alertMessage ?? "")")
    defer { model.cancelSecondOpinion() }

    #expect(model.shrinkUnavailability(for: meeting) == .meetingBusy, "\(String(describing: model.shrinkUnavailability(for: meeting)))")
}
