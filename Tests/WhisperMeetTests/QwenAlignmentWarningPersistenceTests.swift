import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F30 — the alignment warning produced in WhisperCore must reach the user. The reachable hop is
// AppModel.apply(result:to:): it stores result.alignmentWarning onto the MeetingRecord so
// MeetingDetailView can render it. These tests drive that app-level call over a temp store — the
// SwiftUI advisory itself has no view harness and is verified manually (see the F30 log entry).

@MainActor
private func headyModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QwenAlignmentWarningPersistenceTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    let suite = "WhisperMeet.QwenAlignmentWarningPersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

/// A Qwen result whose alignment failed (no segments, a warning) must land on the stored meeting so
/// the detail view can explain the missing timestamps. Fails before F30 wired the field through.
@MainActor
@Test("A Qwen alignment warning is persisted onto the meeting through the app-level apply (F30)")
func alignmentWarningReachesStoredMeeting() {
    let model = headyModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Qwen meeting", status: .processing))

    let result = TranscriptionResult(
        id: id.uuidString,
        text: "Complete text with no timestamps.",
        languageCode: "en",
        audioDuration: 42,
        confidence: nil,
        segments: [],
        alignmentWarning: "Timestamp alignment unavailable; complete text preserved. RuntimeError: aligner failed"
    )
    model.apply(result: result, to: id)

    let stored = model.store.meeting(id: id)
    #expect(stored?.status == .completed)
    #expect(stored?.alignmentWarning?.contains("Timestamp alignment unavailable") == true)
    #expect(stored?.transcriptText == "Complete text with no timestamps.") // complete text preserved
}

/// A normally aligned result (segments present, no warning) leaves the field nil, so the advisory
/// never shows on a healthy transcript.
@MainActor
@Test("A well-aligned result leaves the meeting's alignment warning nil (F30)")
func wellAlignedResultHasNoWarning() {
    let model = headyModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Healthy meeting", status: .processing))

    let result = TranscriptionResult(
        id: id.uuidString,
        text: "0:00 hello\n0:01 world",
        languageCode: "en",
        audioDuration: 2,
        confidence: 0.9,
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello")],
        alignmentWarning: nil
    )
    model.apply(result: result, to: id)

    #expect(model.store.meeting(id: id)?.alignmentWarning == nil)
}
