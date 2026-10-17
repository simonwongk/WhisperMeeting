import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F838 — a summary and its action-item quotes are stored when Summarize runs. A later hand edit that
// removes a sentence left the summary's prose, and any quote of that sentence, on the meeting page
// and in notes.md, with nothing to say the summary was written from text that is no longer there.
// F455 covers summaries made AFTER an edit only. The summary is the user's, so nothing here changes
// or deletes it: the meeting keeps a digest of the text it was written from, and says so beside the
// summary when the transcript no longer matches.

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub: MeetingSummary
    init(_ stub: MeetingSummary) { self.stub = stub }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        stub
    }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F838-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.makeSummarizer = { _, _ in
        StubSummarizer(MeetingSummary(summary: "Dana is leaving in March.", keyPoints: [], actionItems: [
            "Let Dana go in March",
        ]))
    }
    return model
}

private let segments = [
    TranscriptSegment(speaker: nil, start: 0, end: 5, text: "Kick off the quarterly review."),
    TranscriptSegment(speaker: nil, start: 12, end: 17, text: "We'll let Dana go in March."),
]

@MainActor
private func summarizedMeeting(_ model: AppModel) async throws -> UUID {
    let id = UUID()
    let text = TranscriptFormatter.timestamped(segments)
    model.store.upsert(MeetingRecord(id: id, title: "Staffing", status: .completed, transcriptText: text, segments: segments))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    await model.performSummarization(id: id, engine: .local, apiKey: "", transcript: text, language: nil, style: .balanced)
    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    try #require(items.first?.quote == "We'll let Dana go in March.", "fixture: the quote was not resolved")
    return id
}

@MainActor
@Test("A summary whose quoted sentence is edited out is marked as written from other text, and is kept (F838)")
func editingOutAQuotedSentenceMarksTheSummary() async throws {
    let model = try makeModel()
    let id = try await summarizedMeeting(model)
    #expect(model.store.meeting(id: id)?.staleSummaryNote == nil, "nothing has changed yet")

    model.store.editTranscript(id: id, text: "00:00  Kick off the quarterly review.")

    let meeting = try #require(model.store.meeting(id: id))
    let note = try #require(meeting.staleSummaryNote)
    #expect(note.contains("changed since this summary"))
    // The user's summary is untouched: nothing is rewritten or deleted for them.
    #expect(meeting.summary?.summary == "Dana is leaving in March.")
    #expect(meeting.summary?.actionItems.first?.quote == "We'll let Dana go in March.")
    // notes.md says it beside the summary it qualifies.
    let notes = model.store.notesMarkdown(for: meeting)
    let summaryAt = try #require(notes.range(of: "## Summary"))
    let noteAt = try #require(notes.range(of: note), "notes.md does not carry the note")
    #expect(noteAt.lowerBound > summaryAt.lowerBound)
}

@MainActor
@Test("Re-summarizing the edited transcript clears the note (F838)")
func reSummarizingClearsTheNote() async throws {
    let model = try makeModel()
    let id = try await summarizedMeeting(model)
    let edited = "00:00  Kick off the quarterly review."
    model.store.editTranscript(id: id, text: edited)
    try #require(model.store.meeting(id: id)?.staleSummaryNote != nil)

    await model.performSummarization(id: id, engine: .local, apiKey: "", transcript: edited, language: nil, style: .balanced)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.staleSummaryNote == nil)
    let notes = model.store.notesMarkdown(for: meeting)
    #expect(!notes.contains("changed since this summary"))
}

@Test("A summary written before F838 carries no digest and is never marked (F838)")
func aSummaryWithoutADigestIsNotMarked() {
    let record = MeetingRecord(
        title: "Old", status: .completed, transcriptText: "anything at all",
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: [])
    )
    #expect(record.summaryTranscriptDigest == nil)
    #expect(record.staleSummaryNote == nil)
}

@Test("The digest is of the text, stable across launches, and holds none of it (F838)")
func theDigestIsAStableHash() {
    // SHA-256 of "hello": a published value, so the digest is not Swift's per-process `hashValue`.
    #expect(MeetingRecord.transcriptDigest("hello") == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    #expect(!MeetingRecord.transcriptDigest("We'll let Dana go in March.").contains("Dana"))
}

@Test("An index written before the digest existed decodes, and a digest round-trips (F838)")
func theDigestWireFormat() throws {
    let older = #"""
    {"id":"6F1A0000-0000-4000-8000-000000000838","title":"Planning","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"hello","segments":[],
     "summary":{"summary":"s","keyPoints":[],"actionItems":[]}}
    """#
    let decoded = try JSONDecoder().decode(MeetingRecord.self, from: Data(older.utf8))
    #expect(decoded.summaryTranscriptDigest == nil)
    #expect(decoded.staleSummaryNote == nil)

    var stamped = decoded
    stamped.summaryTranscriptDigest = MeetingRecord.transcriptDigest("hello")
    let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(stamped))
    #expect(restored.summaryTranscriptDigest == stamped.summaryTranscriptDigest)
    #expect(restored.staleSummaryNote == nil, "the text is the one it was written from")
}

@Test("The meeting page shows the note beside the summary (F838)")
func theSummarySectionShowsTheNote() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("staleSummaryNote"))
}
