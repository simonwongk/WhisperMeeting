import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// The transcript handed to a summarization model must not carry the `MM:SS  ` prefix that
// `TranscriptFormatter.timestamped` puts on every segment for the transcript VIEW. The model never
// reads those digits, but it pays for them: measured with the local model's own tokenizer, the
// prefixes were 7,278 of 30,784 prompt tokens (23.6%) on the largest real meeting in the library,
// and 6,004 of 14,014 (42.8%) on another. That is prefill time on the local engine and input-token
// billing on the Claude engine, spent on data the summary cannot use.
//
// The export path already strips them (`TranscriptExporter.swift:120`) and so does the correction
// sheet (`ContentView.swift:3115`); the summarize path did not.
//
// The strip lives in `performSummarization`, the one choke point every caller passes through on the
// way to `makeSummarizer`, so it cannot be skipped by adding a new entry point. These tests pin it
// there for both engines. Deliberately engine-agnostic: the local summarization model may change,
// and this saving belongs to whatever model is behind `makeSummarizer`.

private final class TranscriptCapturingSummarizer: MeetingSummarizer, @unchecked Sendable {
    var received: String?
    let stub = MeetingSummary(summary: "S", keyPoints: ["k"], actionItems: ["a"])

    func summarize(
        transcript: String,
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate
    ) async throws -> MeetingSummary {
        received = transcript
        return stub
    }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizationPromptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "SummarizationPrompt.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private let sampleSegments = [
    TranscriptSegment(speaker: nil, start: 0, end: 4, text: "Let's lock the vendor invoice by Friday."),
    TranscriptSegment(speaker: nil, start: 65, end: 70, text: "Priya owns the migration rollback plan."),
    TranscriptSegment(speaker: nil, start: 3_725, end: 3_730, text: "We ship behind a flag next Tuesday.")
]

@MainActor
@Test("The summarizer is handed the transcript with no MM:SS timestamps")
func summarizerReceivesTranscriptWithoutTimestamps() async throws {
    let model = try makeModel()
    let capturing = TranscriptCapturingSummarizer()
    model.makeSummarizer = { _, _ in capturing }

    let stored = TranscriptFormatter.timestamped(sampleSegments)
    // Precondition: what the store holds really is the timestamped rendering, otherwise this test
    // would pass for the wrong reason.
    #expect(TranscriptFormatter.isTimestamped(stored))

    let id = UUID()
    model.store.upsert(
        MeetingRecord(id: id, title: "M", status: .completed, transcriptText: stored, segments: sampleSegments)
    )

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: stored, language: "en", style: .balanced
    )

    let received = try #require(capturing.received)
    #expect(!TranscriptFormatter.isTimestamped(received))
    #expect(!received.contains("01:05"))
    #expect(!received.contains("62:05"))
}

@MainActor
@Test("Stripping timestamps leaves every word the summary is meant to read")
func strippingPreservesTranscriptContent() async throws {
    let model = try makeModel()
    let capturing = TranscriptCapturingSummarizer()
    model.makeSummarizer = { _, _ in capturing }

    let stored = TranscriptFormatter.timestamped(sampleSegments)
    let id = UUID()
    model.store.upsert(
        MeetingRecord(id: id, title: "M", status: .completed, transcriptText: stored, segments: sampleSegments)
    )

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: stored, language: "en", style: .balanced
    )

    let received = try #require(capturing.received)
    for segment in sampleSegments {
        #expect(received.contains(segment.text))
    }
    // One line per segment survives — stripping must not merge or drop lines.
    #expect(received.split(separator: "\n").count == sampleSegments.count)
}

@MainActor
@Test("A user-edited plain-text transcript reaches the summarizer unchanged")
func plainTextTranscriptIsUnchanged() async throws {
    let model = try makeModel()
    let capturing = TranscriptCapturingSummarizer()
    model.makeSummarizer = { _, _ in capturing }

    // A transcript the user rewrote by hand: no timestamps to strip, and a bare "12:30" that is
    // meeting CONTENT rather than a line prefix must survive.
    let edited = "We agreed to move standup to 12:30 tomorrow.\nBudget sign-off is still open."
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: edited))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: edited, language: "en", style: .balanced
    )

    #expect(try #require(capturing.received) == edited)
}

@MainActor
@Test("The Claude engine is handed a stripped transcript too, not just the local engine")
func claudeEngineAlsoReceivesStrippedTranscript() async throws {
    let model = try makeModel()
    let capturing = TranscriptCapturingSummarizer()
    model.makeSummarizer = { _, _ in capturing }

    let stored = TranscriptFormatter.timestamped(sampleSegments)
    let id = UUID()
    model.store.upsert(
        MeetingRecord(id: id, title: "M", status: .completed, transcriptText: stored, segments: sampleSegments)
    )

    await model.performSummarization(
        id: id, engine: .claude, apiKey: "sk-test", transcript: stored, language: "en", style: .balanced
    )

    let received = try #require(capturing.received)
    #expect(!TranscriptFormatter.isTimestamped(received))
}

@MainActor
@Test("Action-item evidence still resolves against segments after the prompt is stripped")
func actionItemEvidenceSurvivesStripping() async throws {
    let model = try makeModel()
    let capturing = TranscriptCapturingSummarizer()
    model.makeSummarizer = { _, _ in capturing }

    let stored = TranscriptFormatter.timestamped(sampleSegments)
    let id = UUID()
    model.store.upsert(
        MeetingRecord(id: id, title: "M", status: .completed, transcriptText: stored, segments: sampleSegments)
    )

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: stored, language: "en", style: .balanced
    )

    // F177 resolves each action item to a supporting segment from the STORED segments, which the
    // strip must not disturb — the summary still lands with its action items intact.
    let summary = try #require(model.store.meeting(id: id)?.summary)
    #expect(summary.actionItems.count == capturing.stub.actionItems.count)
}
