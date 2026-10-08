import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — a shrunk capture keeps its stem so it is still recognised as what it is: speaker analysis
// still runs on it, and a lost index still rebuilds it with the right provenance (F273). Verify
// Library and Rebuild Audio are pinned as unchanged: a shrunk folder has neither tracks nor manifest.

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shrunk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("A lost index rebuilds a shrunk capture and a shrunk rebuild with their own provenance (F795)")
func shrunkCapturesAreFinalizedRecordings() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data([1, 2, 3]).write(to: dir.appendingPathComponent("meeting.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir)?.source == .existingCapture)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("meeting.m4a"))
    try Data([1, 2, 3]).write(to: dir.appendingPathComponent("meeting-recovered.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir)?.source == .rebuiltSourceTracks)
}

@Test("An empty shrunk file is not a finalized recording (F795)")
func anEmptyShrunkFileIsNotFinalized() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("meeting.m4a"))
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: dir) == nil)
}

@Test("A shrunk folder has no Verify Library problem and no Rebuild Audio offer (F795)")
func aShrunkFolderLooksHealthy() throws {
    let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
    let m4a = dir.appendingPathComponent("meeting.m4a")
    try Data(count: 4_000).write(to: m4a)
    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: m4a, sourceTracks: [], indexDurationSeconds: 3, rawTracksWithoutManifest: false))
    #expect(!findings.contains { $0.isProblem })
    #expect(SourceRebuild.offer(in: dir, currentDuration: 3) == nil)
}

@Test("Speaker analysis accepts a shrunk capture as a native recording (F795)")
@MainActor
func speakerAnalysisAcceptsAShrunkCapture() throws {
    let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let id = UUID()
    let meeting = MeetingRecord(id: id, title: "Sync", duration: 3, recordingPath: "Recordings/\(id)/meeting.m4a",
                                status: .completed, transcriptText: "Hi.",
                                segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Hi.")])
    #expect(model.speakerAnalysisUnavailability(for: meeting) != .unsupportedRecording)
}
