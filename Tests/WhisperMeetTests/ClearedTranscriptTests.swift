import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F837 — clearing the whole transcript in the editor is the strongest redaction a user can make, and
// it was the one edit nothing honoured. `TranscriptFormatter.isEdited` returned false for empty text,
// so a cleared transcript read as "unedited": Ask cited and embedded the original segments, a new
// summary quoted them, the notes.md beside the audio carried their words as marker context, and the
// line tools rebuilt the text from them — writing back everything the user had just removed.
//
// "Cleared" and "never transcribed" are told apart by the segments, not by a new field: a meeting
// that was never transcribed has none, and the only write that leaves segments under empty text is
// the editor's. Every edit below goes through that path, `MeetingStore.editTranscript`.

private actor PassageLog {
    var texts: [String] = []
    func record(_ batch: [String]) { texts += batch }
    func clear() { texts = [] }
}

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub: MeetingSummary
    init(_ stub: MeetingSummary) { self.stub = stub }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        stub
    }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F837-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999),
                         recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F837.\(UUID().uuidString)")!)
    model.isAskEmbeddingModelInstalled = { true }
    model.refreshRuntime()
    return model
}

/// Scored, so the notes' Confidence section and the quality review have something to say.
private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text, avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)
}

private let originalSegments = [
    seg(0, "Kick off the quarterly review."),
    seg(12.4, "We'll let Dana go in March."),
    seg(30.7, "We'll sue Acme next week."),
]

@MainActor
private func upsertMeeting(_ model: AppModel, segments: [TranscriptSegment] = originalSegments,
                           markers: [RecordingMarker]? = nil) throws -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Staffing", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments, markers: markers
    ))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    return id
}

@MainActor
@Test("A cleared transcript is never cited by keyword Ask (F837)")
func keywordAskNeverCitesAClearedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertMeeting(model)
    // The precondition: before the clear, the sentence is there to be found.
    try #require(await model.askMeetings(query: "Dana", scope: MeetingScope()).map(\.snippet) == ["We'll let Dana go in March."])

    model.store.editTranscript(id: id, text: "")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.segments == originalSegments, "the editor leaves the segments alone — which is the whole problem")
    #expect(model.store.isTranscriptEdited(meeting), "a cleared transcript is edited, to nothing")

    #expect(await model.askMeetings(query: "Dana March", scope: MeetingScope()).isEmpty)
    #expect(await model.askMeetings(query: "Acme", scope: MeetingScope()).isEmpty)
    #expect(await model.askMeetings(query: "quarterly review", scope: MeetingScope()).isEmpty)
}

@MainActor
@Test("A cleared transcript is never handed to the search model, and never cited by meaning (F837)")
func meaningAskNeverEmbedsAClearedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertMeeting(model)
    let log = PassageLog()
    // Every text points the same way, so every passage clears the similarity floor: a cleared
    // meeting still in the index would be cited whatever its words.
    model.askEmbedder = { texts, kind in
        if kind == .passage { await log.record(texts) }
        return (2, texts.flatMap { _ in [Float(1), 0] })
    }
    let before = await model.askMeetingsByMeaning(query: "staffing changes", scope: MeetingScope())
    try #require(before.contains { $0.meetingID == id }, "the precondition: the meeting is found by meaning")

    model.store.editTranscript(id: id, text: "   \n  ")
    await log.clear()
    let after = await model.askMeetingsByMeaning(query: "staffing changes", scope: MeetingScope())

    #expect(!after.contains { $0.meetingID == id })
    #expect(await log.texts.isEmpty, "a cleared transcript has no passages to embed")
}

@MainActor
@Test("A summary made after the transcript was cleared quotes nothing from it (F837)")
func actionItemsQuoteNothingFromAClearedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertMeeting(model)
    model.store.editTranscript(id: id, text: "")
    model.makeSummarizer = { _, _ in
        StubSummarizer(MeetingSummary(summary: "s", keyPoints: [], actionItems: [
            "Follow up with Acme next week", "Let Dana go in March",
        ]))
    }

    await model.performSummarization(id: id, engine: .local, apiKey: "", transcript: "", language: nil, style: .balanced)

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    try #require(items.count == 2)
    #expect(items.map(\.quote) == [nil, nil])
    #expect(items.map(\.timestamp) == [nil, nil])
}

@MainActor
@Test("The notes beside the audio carry no marker context or confidence from a cleared transcript (F837)")
func notesSidecarCarriesNothingFromAClearedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertMeeting(model, markers: [RecordingMarker(offset: 13, label: "Decision")])
    let sidecar = model.store.recordingDirectoryURL(for: id).appendingPathComponent("notes.md")
    model.store.flushPendingEdits()
    let original = try String(contentsOf: sidecar, encoding: .utf8)
    try #require(original.contains("Dana"), "the precondition: the marker's context quotes the line")
    try #require(original.contains("## Confidence"))

    model.store.editTranscript(id: id, text: "")
    model.store.flushPendingEdits()
    let cleared = try String(contentsOf: sidecar, encoding: .utf8)

    #expect(!cleared.contains("Dana"))
    #expect(!cleared.contains("Acme"))
    #expect(!cleared.contains("## Confidence"), "a score of lines the user removed is a claim about nothing shown")
    #expect(cleared.contains("Decision"), "the marker itself still lists")
}

@MainActor
@Test("Quality flags and repetition notices are withheld for a cleared transcript (F837)")
func segmentOverlaysAreWithheldForAClearedTranscript() async throws {
    let model = try makeModel()
    // A stuck decode's low-probability echo, five times over, so Remove Repeated Lines has something
    // to offer and the quality review something to flag.
    let looped = [seg(0, "Hello.")] + (1...5).map {
        TranscriptSegment(speaker: nil, start: Double($0) * 5, end: Double($0) * 5 + 5, text: "Thanks for watching.", avgLogprob: -1.6)
    }
    let id = try upsertMeeting(model, segments: looped)
    try #require(model.removableRepeatCount(for: id) > 0, "the precondition: the echoes are offered for removal")
    try #require(!TranscriptReviewOverlay(.init(segments: looped, isEdited: false)).flagsByIndex.isEmpty)

    model.store.editTranscript(id: id, text: "")
    let meeting = try #require(model.store.meeting(id: id))
    let edited = model.store.isTranscriptEdited(meeting)

    #expect(edited)
    #expect(model.removableRepeatCount(for: id) == 0)
    // What the Read view draws its flags from, given the edited state the view passes it.
    let overlay = TranscriptReviewOverlay(TranscriptReviewOverlay.Input(segments: meeting.segments, isEdited: edited))
    #expect(overlay.flagsByIndex.isEmpty)
}

@MainActor
@Test("The line tools refuse a cleared transcript rather than writing back what was cleared (F837)")
func lineToolsRefuseAClearedTranscript() async throws {
    let model = try makeModel()
    let id = try upsertMeeting(model)
    model.store.editTranscript(id: id, text: "")

    #expect(model.lineRemovalBlockedReason(for: id) == AppModel.editedTranscriptReason)
    #expect(model.removeTranscriptLines(at: IndexSet(integer: 1), from: id) == nil)
    let replace = model.applySecondOpinionSpan(
        TranscriptComparisonSpan(kind: .diverge, start: 30.7, primaryText: "We'll sue Acme next week.",
                                 secondaryText: "We'll see Acme next week."),
        to: id
    )
    #expect(replace == .refused(AppModel.secondOpinionReplaceRefusedForEdits))
    model.applyGlossaryCorrections([GlossaryCorrection(segmentIndex: 2, from: "sue", to: "see")], to: id)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.transcriptText == "", "every tool above rebuilds the text from the lines, which un-clears it")
    #expect(meeting.segments == originalSegments)
}

@MainActor
@Test("A meeting that was never transcribed is not a cleared one (F837)")
func neverTranscribedIsNotCleared() async throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Just recorded", status: .recorded))
    let meeting = try #require(model.store.meeting(id: id))
    #expect(!model.store.isTranscriptEdited(meeting))
    // Lines whose rendering is itself empty: empty text is that rendering, not a clear.
    let blank = [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "  ")]
    #expect(!TranscriptFormatter.isEdited(transcriptText: "", segments: blank))
}
