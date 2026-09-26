import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F164 — local summarization is the default engine; Claude is opt-in. These drive the AppModel
// wiring: the chosen engine reaches makeSummarizer, the full user path stores a local summary, and
// the honest fallbacks fire (local model missing → offer install; without silently doing nothing).

private final class RecordingSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub = MeetingSummary(summary: "S", keyPoints: ["k1"], actionItems: ["a1"])
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
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

// F499 — the "Send to Claude?" confirmation used to live only in ContentView's button switch, so
// AppModel.summarize(id:) itself would send to Claude whenever the engine was `.claude` and a key
// existed, with no confirmation parameter of its own. These pin the gate headlessly, without ever
// touching the real Keychain: the refusal fires from the confirmation check alone, before
// `KeychainStore.string(for:)` is reached at all, so it cannot depend on — or be defeated by —
// whatever the developer's own login keychain happens to hold.

@MainActor
@Test("Claude summarization refuses without AppModel's own confirmation, before it even checks for a key (F499)")
func claudeSummarizeRefusesWithoutConfirmation() throws {
    let model = try makeModel()
    model.summarizationEngine = .claude

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))
    model.summarize(id: id, style: .balanced, template: .general)   // cloudUploadConfirmed defaults to false

    #expect(model.alertMessage?.contains("confirmation") == true)
    #expect(model.alertMessage != SummarizerError.missingAPIKey.localizedDescription)
    #expect(model.activeSummarizationID == nil)
    #expect(model.store.meeting(id: id)?.summary == nil)
}

// Deliberately no "confirmed → proceeds" AppModel test: `summarize(id:)`'s `.claude` branch reads
// the REAL system Keychain (`KeychainStore.string(for:)`, no injection seam) with no way to fake a
// key. A confirmed call on a machine that happens to have a real Claude key saved would start an
// actual background Task against the real Claude API with real credentials — unbounded by this
// test's own lifetime. `claudeSummarizeRefusesWithoutConfirmation` above proves the gate refuses
// before that lookup ever runs; the source assertion below proves the one call site that can pass
// `cloudUploadConfirmed: true` is gated behind the user's own confirmation press. Between the two,
// the pre-existing (and unrelated) key check needs no new test of its own here.

@Test("The confirmation dialog's own button is the one call site that passes AppModel's confirmation (F499)")
func onlyTheConfirmationButtonPassesCloudUploadConfirmed() throws {
    // F306's precedent: a control's reachability is checkable only as source text here (F174's
    // standing reason — the WhisperMeet target has no view-render harness). Comments stripped, so
    // a mention of the parameter name in prose cannot satisfy this the way F285's false positive did.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let anchor = try #require(
        source.range(of: #"Button("Send to Claude")"#),
        "the confirmation alert's own button must exist"
    )
    let after = source[anchor.upperBound...].prefix(200)
    #expect(
        after.contains("cloudUploadConfirmed: true"),
        "the confirmation dialog's button must pass cloudUploadConfirmed: true — the one user action that satisfies the F499 gate"
    )
}
