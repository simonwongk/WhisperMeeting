import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F81 — the SummaryStyle core (delivers F63) shipped tested but unreachable: performSummarization
// always built a ClaudeSummarizer inline and called the 2-arg convenience, so the style was pinned to
// .balanced. Wiring adds a makeSummarizer seam + a style parameter; this drives the app-level call and
// asserts the chosen style reaches the summarizer and the result is stored.

private final class StyleRecordingSummarizer: MeetingSummarizer, @unchecked Sendable {
    private(set) var recordedStyle: SummaryStyle?
    let stub = MeetingSummary(summary: "S", keyPoints: ["k1"], actionItems: ["a1"])
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        recordedStyle = style
        return stub
    }
}

@MainActor
@Test("The chosen summary style reaches the summarizer through AppModel, and the summary is stored (F81)")
func summaryStyleReachesSummarizer() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummaryStyleWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F81.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let recorder = StyleRecordingSummarizer()
    model.makeSummarizer = { _, _ in recorder }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    await model.performSummarization(id: id, engine: .claude, apiKey: "test-key", transcript: "hello world", language: "en", style: .brief)

    #expect(recorder.recordedStyle == .brief)
    #expect(model.store.meeting(id: id)?.summary == recorder.stub)
}
