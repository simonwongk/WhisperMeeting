import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F873 — a meeting transcribed before F287 (2026-09-17) stored its text with every timestamp rounded
// down; today's rendering rounds to the nearest second. Through the app, such a meeting read as
// hand-edited: its quality flags were hidden and every line tool said "Unavailable after manual
// edits". The text is written out in the old format by hand, and is never rewritten by reading it.

@MainActor
@Test("A meeting transcribed before F287 is not treated as hand-edited, and its stored text is left as it was (F873)")
func preF287MeetingIsNotHandEdited() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F873-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let segments = [
        TranscriptSegment(speaker: nil, start: 30.7, end: 34.7, text: "We'll ship on Friday.", avgLogprob: -1.6),
        TranscriptSegment(speaker: nil, start: 35.2, end: 39.2, text: "Sounds good.", avgLogprob: -0.2),
    ]
    let written = "00:30  We'll ship on Friday.\n00:35  Sounds good."
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Before September", status: .completed, transcriptText: written, segments: segments,
        transcriptNormalized: true
    ))
    let meeting = try #require(model.store.meeting(id: id))

    #expect(!model.store.isTranscriptEdited(meeting))
    #expect(model.lineRemovalBlockedReason(for: id) == nil, "the line tools are available, as on any untouched transcript")
    // The Read view's quality flags come back with the edited state the view passes.
    let overlay = TranscriptReviewOverlay(.init(segments: meeting.segments, isEdited: model.store.isTranscriptEdited(meeting)))
    #expect(overlay.flagsByIndex.keys.sorted() == [0])
    #expect(model.store.meeting(id: id)?.transcriptText == written, "reading it never rewrites the stored text")
}
