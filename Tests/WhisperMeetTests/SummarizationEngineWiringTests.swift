import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F164 — local summarization is the default engine; Claude is opt-in. These drive the AppModel
// wiring: the chosen engine reaches makeSummarizer, the full user path stores a local summary, and
// the honest fallbacks fire (local model missing → offer install; without silently doing nothing).

private final class RecordingSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub = MeetingSummary(summary: "S", keyPoints: ["k1"], actionItems: ["a1"])
    func summarize(transcript: String, language: String?, style: SummaryStyle) async throws -> MeetingSummary {
        stub
    }
}

private final class EngineBox: @unchecked Sendable {
    var engine: SummarizationEngine?
    var apiKey: String?
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizationEngineWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F164.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Summarization defaults to the local engine with no stored preference (F164)")
func summarizationDefaultsToLocal() throws {
    let model = try makeModel()
    #expect(model.summarizationEngine == .local)
}

@MainActor
@Test("performSummarization threads the chosen engine and key into makeSummarizer and stores the result (F164)")
func engineReachesMakeSummarizer() async throws {
    let model = try makeModel()
    let recorder = RecordingSummarizer()
    let box = EngineBox()
    model.makeSummarizer = { engine, apiKey in
        box.engine = engine
        box.apiKey = apiKey
        return recorder
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "hello world", language: "en", style: .balanced
    )
    #expect(box.engine == .local)
    #expect(box.apiKey == "")
    #expect(model.store.meeting(id: id)?.summary == recorder.stub)

    await model.performSummarization(
        id: id, engine: .claude, apiKey: "sk-test", transcript: "hello world", language: "en", style: .brief
    )
    #expect(box.engine == .claude)
    #expect(box.apiKey == "sk-test")
}

@MainActor
@Test("The full local summarize path reaches the store when the model is installed (F164 reachability)")
func localSummarizePathStoresSummary() async throws {
    let model = try makeModel()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    let recorder = RecordingSummarizer()
    let box = EngineBox()
    model.makeSummarizer = { engine, _ in box.engine = engine; return recorder }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    model.summarize(id: id)
    #expect(model.activeSummarizationID == id) // guards passed; a job started (no key required)

    var spins = 0
    while model.activeSummarizationID != nil, spins < 100_000 {
        await Task.yield()
        spins += 1
    }
    #expect(box.engine == .local)
    #expect(model.store.meeting(id: id)?.summary == recorder.stub)
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("Local summary with the model not installed offers install instead of silently failing (F164)")
func localSummarizeRequiresInstalledModel() throws {
    let model = try makeModel()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { false }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))
    model.summarize(id: id)

    #expect(model.alertMessage == SummarizerError.modelNotInstalled.localizedDescription)
    #expect(model.activeSummarizationID == nil)
    #expect(model.store.meeting(id: id)?.summary == nil)
}
