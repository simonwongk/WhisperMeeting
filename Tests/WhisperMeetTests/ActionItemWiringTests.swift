import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F177 — action item cards. Drives the AppModel wiring: editing an item's done/owner/due persists to
// the index, and summarizing resolves each item's supporting timestamp from the meeting's segments.

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub: MeetingSummary
    init(_ stub: MeetingSummary) { self.stub = stub }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        stub
    }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActionItemWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F177.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Editing an action item's done/owner/due persists to the meeting index (F177)")
func editingActionItemPersists() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed, transcriptText: "hello",
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: ["Email vendor", "Call Bob"])
    ))

    model.updateActionItem(at: 0, for: id) { $0.done = true }
    model.updateActionItem(at: 1, for: id) { $0.owner = "Bob"; $0.due = "Fri" }

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items[0].done)
    #expect(items[1].owner == "Bob")
    #expect(items[1].due == "Fri")
    #expect(!items[1].done)
}

@MainActor
@Test("An out-of-range action-item edit is a no-op (F177)")
func outOfRangeEditIsNoOp() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: ["only one"])
    ))
    model.updateActionItem(at: 5, for: id) { $0.done = true } // must not crash or mutate
    #expect(model.store.meeting(id: id)?.summary?.actionItems == ["only one"])
}

@MainActor
@Test("Summarizing resolves each action item's supporting timestamp from the segments (F177)")
func summarizeResolvesTimestamps() async throws {
    let model = try makeModel()
    let summarizer = StubSummarizer(MeetingSummary(
        summary: "s", keyPoints: [], actionItems: ["Alice to send the budget spreadsheet"]
    ))
    model.makeSummarizer = { _, _ in summarizer }

    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "Kick off the project."),
        TranscriptSegment(speaker: nil, start: 12, end: 20, text: "Alice will send the budget spreadsheet to finance by Friday."),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .balanced
    )

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items[0].timestamp == 12)
    #expect(items[0].quote?.contains("budget spreadsheet") == true)
}
