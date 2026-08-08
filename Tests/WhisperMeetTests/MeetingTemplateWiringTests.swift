import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F178 — the meeting template chosen in the UI must reach the summarizer through the AppModel call, the
// same way F81 wired the style. Drives the app-level call and asserts the template threads through.

private final class TemplateRecordingSummarizer: MeetingSummarizer, @unchecked Sendable {
    private(set) var recordedTemplate: MeetingTemplate?
    private(set) var recordedStyle: SummaryStyle?
    let stub = MeetingSummary(summary: "S", keyPoints: ["k1"], actionItems: ["a1"])
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        recordedStyle = style
        recordedTemplate = template
        return stub
    }
}

@MainActor
@Test("The chosen meeting template reaches the summarizer through AppModel (F178)")
func templateReachesSummarizer() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingTemplateWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F178.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let recorder = TemplateRecordingSummarizer()
    model.makeSummarizer = { _, _ in recorder }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "hello world",
        language: "en", style: .detailed, template: .decisionLog
    )

    #expect(recorder.recordedTemplate == .decisionLog)
    #expect(recorder.recordedStyle == .detailed)
    #expect(model.store.meeting(id: id)?.summary == recorder.stub)
}
