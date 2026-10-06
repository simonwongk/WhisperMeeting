import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F455 — a hand edit (`MeetingStore.editTranscript`) rewrites `transcriptText` and never the stored
// segments. Ask's keyword and meaning ranking, the passages a written answer is grounded in, and the
// F177 action-item quotes all read the segments, so a sentence the user deleted or corrected kept
// being cited. Every edit below goes through the editor's own path — the F331 test this replaces
// faked an edit by assigning `segments`, which the editor never does.

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub: MeetingSummary
    init(_ stub: MeetingSummary) { self.stub = stub }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        stub
    }
}

private actor PassageLog {
    var texts: [String] = []
    func record(_ batch: [String]) { texts += batch }
    func clear() { texts = [] }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskHandEdit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F455.\(UUID().uuidString)")!)
    model.isAskEmbeddingModelInstalled = { true }
    model.refreshRuntime()
    return model
}

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text)
}

private let originalSegments = [
    seg(0, "Kick off the quarterly review."),
    seg(12.4, "We'll let Dana go in March."),
    seg(30.7, "We'll sue Acme next week."),
]

/// The Dana line deleted and "sue" corrected to "see", as a user would type it in the editor.
private let editedText = "00:00  Kick off the quarterly review.\n00:30  We'll see Acme next week."

@MainActor
private func upsertStaffingMeeting(_ model: AppModel) throws -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Staffing", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(originalSegments), segments: originalSegments
    ))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    return id
}

@MainActor
@Test("Keyword Ask reads a hand-edited transcript as the user left it: a deleted line is never cited, a corrected one is (F455)")
func keywordAskReadsTheEditedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertStaffingMeeting(model)
    // The precondition: before any edit, the sentence is there to be found.
    #expect(await model.askMeetings(query: "Dana", scope: MeetingScope()).map(\.snippet) == ["We'll let Dana go in March."])

    model.store.editTranscript(id: id, text: editedText)
    let meeting = try #require(model.store.meeting(id: id))
    try #require(model.store.isTranscriptEdited(meeting))
    #expect(meeting.segments == originalSegments, "the editor leaves the segments alone — which is the whole problem")

    #expect(await model.askMeetings(query: "Dana March", scope: MeetingScope()).isEmpty)
    #expect(await model.askMeetings(query: "sue", scope: MeetingScope()).isEmpty)
    let acme = await model.askMeetings(query: "Acme", scope: MeetingScope())
    #expect(acme.map(\.snippet) == ["We'll see Acme next week."])
    // Two lines no longer align with three segments, so the line's own visible MM:SS is its time.
    #expect(acme.first?.timestamp == 30)
}

@MainActor
@Test("A correction inside lines that still align keeps each line's precise original timing (F455)")
func alignedCorrectionKeepsOriginalTiming() async throws {
    let model = try makeModel()
    let id = try upsertStaffingMeeting(model)
    let corrected = TranscriptFormatter.timestamped(originalSegments).replacingOccurrences(of: "sue", with: "see")
    model.store.editTranscript(id: id, text: corrected)

    #expect(await model.askMeetings(query: "sue", scope: MeetingScope()).isEmpty)
    let acme = try #require(await model.askMeetings(query: "Acme", scope: MeetingScope()).first)
    #expect(acme.snippet == "We'll see Acme next week.")
    #expect(acme.timestamp == 30.7)
}

@MainActor
@Test("Search by meaning re-embeds the edited lines, never hands the model a deleted line, and never cites one (F455)")
func meaningAskNeverSeesTheDeletedLine() async throws {
    let model = try makeModel()
    let id = try upsertStaffingMeeting(model)
    let log = PassageLog()
    // Every text points the same way, so every passage clears the similarity floor: if a deleted
    // line were still in the index, nothing about its wording could keep it out of the results.
    model.askEmbedder = { texts, kind in
        if kind == .passage { await log.record(texts) }
        return (2, texts.flatMap { _ in [Float(1), 0] })
    }

    _ = await model.askMeetingsByMeaning(query: "staffing changes", scope: MeetingScope())
    let directory = model.store.recordingDirectoryURL(for: id)
    try #require(SegmentEmbeddings.read(from: directory, modelID: AskEmbeddingRuntime.modelID,
                                        texts: originalSegments.map(\.text)) != nil,
                 "the precondition: an index of the original segments is saved beside the recording")

    model.store.editTranscript(id: id, text: editedText)
    await log.clear()
    let fused = await model.askMeetingsByMeaning(query: "staffing changes", scope: MeetingScope())

    #expect(!fused.isEmpty)
    #expect(!fused.contains { $0.snippet.contains("Dana") || $0.snippet.contains("sue") })
    #expect(await log.texts == ["Kick off the quarterly review.", "We'll see Acme next week."])
    // The saved index is now the edited text's, so the stale one is gone from disk too.
    #expect(SegmentEmbeddings.read(from: directory, modelID: AskEmbeddingRuntime.modelID,
                                   texts: originalSegments.map(\.text)) == nil)
    #expect(SegmentEmbeddings.read(from: directory, modelID: AskEmbeddingRuntime.modelID,
                                   texts: ["Kick off the quarterly review.", "We'll see Acme next week."]) != nil)
}

@MainActor
@Test("A summary of a hand-edited transcript quotes the edited line, and nothing for an item whose line was deleted (F455)")
func actionItemQuotesReadTheEditedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertStaffingMeeting(model)
    model.store.editTranscript(id: id, text: editedText)
    model.makeSummarizer = { _, _ in
        StubSummarizer(MeetingSummary(summary: "s", keyPoints: [], actionItems: [
            "Follow up with Acme next week", "Let Dana go in March",
        ]))
    }

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: editedText, language: nil, style: .balanced
    )

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    try #require(items.count == 2)
    #expect(items[0].quote == "We'll see Acme next week.")
    #expect(items[0].timestamp == 30)
    #expect(items[1].quote == nil, "the only line that supported it was deleted")
    #expect(items[1].timestamp == nil)
}
