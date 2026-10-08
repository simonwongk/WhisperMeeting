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

/// Polls `condition` every 5 ms under a 30 s cap and requires it, so a timeout fails as a timeout (F639).
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

/// `localSummariesSupported` is pinned, never left to the host: the real default is a compile-time
/// `#if arch(arm64)`, so a test that relied on it would assert this Mac's architecture (F566).
@MainActor
private func makeModel(
    defaults: UserDefaults = UserDefaults(suiteName: testSuiteName())!,
    localSummariesSupported: Bool = true,
    claudeKeyStore: ClaudeKeyStore = .inMemory()
) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizationEngineWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        localSummariesSupported: localSummariesSupported, claudeKeyStore: claudeKeyStore
    )
}

@MainActor
@Test("Summarization defaults to the local engine with no stored preference (F164)")
func summarizationDefaultsToLocal() throws {
    let model = try makeModel(localSummariesSupported: true)
    #expect(model.summarizationEngine == .local)
}

// F566 — on an Intel Mac the default was `.local` too, so Summarize told the user to install a
// model that Settings offers no way to install there.

@MainActor
@Test("On a Mac without local summaries, a missing preference defaults to Claude and is not persisted (F566)")
func summarizationDefaultsToClaudeWithoutLocalSupport() throws {
    let defaults = UserDefaults(suiteName: testSuiteName())!
    let model = try makeModel(defaults: defaults, localSummariesSupported: false)
    #expect(model.summarizationEngine == .claude)
    // A default is not a choice: nothing is written, so the user's first pick is still theirs.
    #expect(defaults.string(forKey: "summarizationEngine") == nil)
}

@MainActor
@Test("A stored local choice on a Mac without local summaries is kept, and Summarize says why it cannot run (F566)")
func storedLocalChoiceOnUnsupportedMacRefusesHonestly() throws {
    let defaults = UserDefaults(suiteName: testSuiteName())!
    defaults.set("local", forKey: "summarizationEngine")
    let model = try makeModel(defaults: defaults, localSummariesSupported: false)
    #expect(model.summarizationEngine == .local)
    model.isSummarizerModelInstalled = { false }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))
    model.summarize(id: id)

    let alert = try #require(model.alertMessage)
    #expect(alert.contains("Apple-silicon"))
    // Choosing Claude sends the transcript to Anthropic, so the alert must not offer it as a way to
    // summarize "on this Mac" — the privacy claim F555 removed from the Settings caption.
    #expect(alert.contains("Anthropic"))
    #expect(!alert.contains("on this Mac"))
    #expect(alert != SummarizerError.modelNotInstalled.localizedDescription)
    #expect(model.activeSummarizationID == nil)
    #expect(model.store.meeting(id: id)?.summary == nil)
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

    // Polls the job's own state under a wall-clock cap, never a yield count (F639), and requires it:
    // a budget of `Task.yield()`s expires under a starved scheduler before the summary lands, and
    // would then fail the three assertions below as claims about the store.
    try await waitUntil("the summarization to finish") { model.activeSummarizationID == nil }
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
// touching the real Keychain: the refusal fires from the confirmation check alone, before the
// key is read at all, so it cannot depend on — or be defeated by — whatever the developer's own login
// keychain happens to hold.

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

// The positive half (F442). There used to be deliberately no "confirmed → proceeds" test here: the `.claude`
// branch read the REAL system Keychain, so on a machine with a Claude key saved it would have started a
// background task against the real API with real credentials. The key now comes from the model's own
// `ClaudeKeyStore`, so these hand it an in-memory one: a key that exists only in the test, and a summarizer
// that never leaves the process.

@MainActor
@Test("A confirmed Claude summarize with a saved key reaches the summarizer with that key (F499)")
func confirmedClaudeSummarizeUsesTheSavedKey() async throws {
    let model = try makeModel(claudeKeyStore: .inMemory("sk-ant-fixture"))
    model.summarizationEngine = .claude
    let recorder = RecordingSummarizer()
    let box = EngineBox()
    model.makeSummarizer = { engine, apiKey in
        box.engine = engine
        box.apiKey = apiKey
        return recorder
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    model.summarize(id: id, cloudUploadConfirmed: true)
    try await waitUntil("the summary to be stored") { model.store.meeting(id: id)?.summary != nil }

    #expect(box.engine == .claude)
    #expect(box.apiKey == "sk-ant-fixture", "the saved key is what reaches the summarizer")
    #expect(model.store.meeting(id: id)?.summary == recorder.stub)
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("A confirmed Claude summarize with no saved key is refused and nothing is sent (F499)")
func confirmedClaudeSummarizeWithoutAKeyIsRefused() throws {
    let model = try makeModel(claudeKeyStore: .inMemory())
    model.summarizationEngine = .claude
    let box = EngineBox()
    model.makeSummarizer = { engine, apiKey in
        box.engine = engine
        return RecordingSummarizer()
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    model.summarize(id: id, cloudUploadConfirmed: true)

    #expect(model.alertMessage == SummarizerError.missingAPIKey.localizedDescription)
    #expect(model.activeSummarizationID == nil)
    #expect(box.engine == nil, "a summarizer was made although there was no key to send with")
}

@MainActor
@Test("A saved key does not stand in for the confirmation: unconfirmed Claude summarize sends nothing (F499)")
func aSavedKeyDoesNotReplaceTheConfirmation() throws {
    let model = try makeModel(claudeKeyStore: .inMemory("sk-ant-fixture"))
    model.summarizationEngine = .claude
    let box = EngineBox()
    model.makeSummarizer = { engine, _ in
        box.engine = engine
        return RecordingSummarizer()
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "hello world"))

    model.summarize(id: id)   // cloudUploadConfirmed defaults to false

    #expect(model.alertMessage?.contains("confirmation") == true)
    #expect(model.activeSummarizationID == nil)
    #expect(box.engine == nil, "a transcript was handed to a Claude summarizer without the user's confirmation")
}

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

// F467 Part 2 — a summary that comes back in a different language or Chinese script than its
// transcript must carry an advisory, recomputed on every summarize (never left stale from an
// earlier attempt). Reachable through the real `performSummarization` path, over a real
// `MeetingStore`, exactly like `engineReachesMakeSummarizer` above — the only substitution is the
// summarizer itself, through the existing `makeSummarizer` seam.

private final class FixedOutputSummarizer: MeetingSummarizer, @unchecked Sendable {
    let output: MeetingSummary
    init(_ output: MeetingSummary) { self.output = output }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        output
    }
}

@MainActor
@Test("A summary that translates a Chinese meeting into English is flagged, reachable through performSummarization (F467)")
func summarizeFlagsATranslatedSummary() async throws {
    let model = try makeModel()
    let translated = MeetingSummary(
        summary: "We decided to release the new version on October 15.", keyPoints: [], actionItems: []
    )
    model.makeSummarizer = { _, _ in FixedOutputSummarizer(translated) }

    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: "我們決定新版本在十月十五號發佈，前提是測試全部通過。"
    ))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "",
        transcript: "我們決定新版本在十月十五號發佈，前提是測試全部通過。",
        language: "zh", style: .balanced
    )

    let warning = try #require(model.store.meeting(id: id)?.summaryLanguageWarning)
    #expect(warning.contains("English"))
}

@MainActor
@Test("A same-language re-summarize clears an earlier summary's language warning (F467)")
func resummarizeClearsAStaleLanguageWarning() async throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: "我們決定新版本在十月十五號發佈。",
        summary: MeetingSummary(summary: "old", keyPoints: [], actionItems: []),
        summaryLanguageWarning: "a stale warning from an earlier, mistranslated summary"
    ))

    model.makeSummarizer = { _, _ in
        FixedOutputSummarizer(MeetingSummary(summary: "我們決定發佈新版本。", keyPoints: [], actionItems: []))
    }
    await model.performSummarization(
        id: id, engine: .local, apiKey: "",
        transcript: "我們決定新版本在十月十五號發佈。", language: "zh", style: .balanced
    )

    #expect(model.store.meeting(id: id)?.summaryLanguageWarning == nil)
}
