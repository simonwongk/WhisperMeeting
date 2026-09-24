import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F426 — speaker labels are drawn fresh from the analysis's turns and each line's OWN bounds, so a
// removal that only deletes lines leaves every surviving label exactly as it was. The artifact's
// timing fingerprint could not tell that from a re-transcription, so one Delete Line showed "these
// labels no longer line up" until the user re-ran a minutes-long analysis.

private func line(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Two voices: the lecturer (cluster 0) and a student (cluster 1) who speaks twice. Two student
/// lines, because deleting a voice's ONLY line leaves a one-voice transcript, which rightly shows no
/// labels at all (F339) — that is not what this ticket is about.
private let lecture = [
    line("Good morning, everyone.", 0, 3),
    line("别笑，别笑。", 3.2, 4.8),
    line("Let us start with chapter two.", 5, 8),
    line("真是很别扭。", 8.2, 10),
]
private let turns = [
    SpeakerTurn(startSeconds: 0, endSeconds: 3.1, clusterID: 0, kind: .speech),
    SpeakerTurn(startSeconds: 3.1, endSeconds: 4.9, clusterID: 1, kind: .speech),
    SpeakerTurn(startSeconds: 4.9, endSeconds: 8.1, clusterID: 0, kind: .speech),
    SpeakerTurn(startSeconds: 8.1, endSeconds: 10, clusterID: 1, kind: .speech),
]

@MainActor
private func analysedMeeting(
    segments: [TranscriptSegment] = lecture,
    fingerprintOf fingerprinted: [TranscriptSegment]? = nil
) throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakerLabelsSurviveLineRemoval-\(UUID().uuidString)")
    let id = UUID()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings/\(id.uuidString)"), withIntermediateDirectories: true
    )
    let defaults = UserDefaults(suiteName: "F426.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "Lecture", duration: 10,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), languageCode: "en",
        segments: segments, transcriptNormalized: true
    ))
    try DiarizationArtifactStore.save(DiarizationArtifactV1(
        meetingID: id,
        recording: DiarizationRecordingReference(
            relativePath: "Recordings/\(id.uuidString)/meeting.wav", sha256: "hash", durationSeconds: 10
        ),
        transcriptTimingFingerprint: TranscriptTimingFingerprint.compute(fingerprinted ?? segments),
        producer: DiarizationProducer(
            runtimeID: "sherpa-onnx", runtimeVersion: "1.13.8",
            segmentationModelSHA256: "seg", embeddingModelSHA256: "emb", clusterThreshold: 0.3
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: turns,
        aliases: ["0": "Lecturer"]
    ), for: id, in: model.store.rootDirectory)
    return (model, id)
}

@MainActor
@Test("Deleting a line keeps the meeting's speaker labels, unchanged on every surviving line (F426)")
func deletingALineKeepsSpeakerLabels() throws {
    let (model, id) = try analysedMeeting()
    #expect(model.speakerReviewState(for: id) == .labeled)
    let before = model.speakerRowLabels(for: id)
    #expect(before[0] == "Lecturer")

    _ = try #require(model.removeTranscriptLines(at: [1], from: id))

    #expect(model.speakerReviewState(for: id) == .labeled)
    let after = model.speakerRowLabels(for: id)
    // Rows 2 and 3 are now rows 1 and 2; each keeps the label it had.
    #expect(after[0] == before[0])
    #expect(after[1] == before[2])
    #expect(after[2] == before[3])
    #expect(after[2] != nil)
}

@MainActor
@Test("Undoing the deletion keeps them too (F426)")
func undoingADeletionKeepsSpeakerLabels() throws {
    let (model, id) = try analysedMeeting()
    let before = model.speakerRowLabels(for: id)
    let removal = try #require(model.removeTranscriptLines(at: [1], from: id))
    #expect(model.undoTranscriptLineRemoval(removal))
    #expect(model.speakerReviewState(for: id) == .labeled)
    #expect(model.speakerRowLabels(for: id) == before)
}

@MainActor
@Test("An analysis that was already stale is not revived by a deletion (F426)")
func aStaleAnalysisStaysStale() throws {
    // Fingerprinted against a transcript the meeting no longer has: a re-transcription happened
    // after the analysis. Re-stamping it on a deletion would present labels nobody re-checked.
    let retimed = [line("Good morning, everyone.", 0, 2.5)] + Array(lecture.dropFirst())
    let (model, id) = try analysedMeeting(fingerprintOf: retimed)
    #expect(model.speakerReviewState(for: id) == .stale)
    _ = try #require(model.removeTranscriptLines(at: [1], from: id))
    #expect(model.speakerReviewState(for: id) == .stale)
}

@MainActor
@Test("Remove Repeated Lines keeps them as well, because the line it keeps keeps its own timing (F426, F422)")
func removingRepeatsKeepsSpeakerLabels() throws {
    // The aside loops: four copies inside the student's turn. F422 used to widen the kept copy's end
    // over the whole loop, which moved a line and so could never keep the analysis.
    let looping = [lecture[0]]
        + (0..<4).map { line("操！", 3.2 + Double($0) * 0.4, 3.5 + Double($0) * 0.4) }
        + [lecture[2], lecture[3]]
    let (model, id) = try analysedMeeting(segments: looping)
    #expect(model.speakerReviewState(for: id) == .labeled)
    _ = try #require(model.removeRepeatedLines(from: id))
    #expect(model.store.meeting(id: id)?.segments.count == 4)
    #expect(model.speakerReviewState(for: id) == .labeled)
}

@Test("Only a change that adds or removes whole lines, never one that moves a line, counts as timing-compatible (F426)")
func timingSubsequenceRule() {
    let a = line("a", 0, 1), b = line("b", 1, 2), c = line("c", 2, 3)
    #expect(TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, b, c], to: [a, c]))
    #expect(TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, c], to: [a, b, c]))
    #expect(TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, b, c], to: [a, b, c]))
    #expect(!TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, b, c], to: [a, line("b", 1, 2.5), c]))
    #expect(!TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, b, c], to: [c, a]))
    // Text is not timing: a correction that rewrites words is not this rule's business.
    #expect(TranscriptTimingFingerprint.onlyAddsOrRemovesLines(from: [a, b], to: [a, line("B!", 1, 2)]))
}
