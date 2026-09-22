import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F316 — the AppModel side of search by meaning, with a fake embedder: each text becomes a
// two-dimensional vector chosen by the test, so what is being checked is the plumbing — index
// once, reuse, rebuild when the transcript changes, fall back to keywords when anything fails.

@MainActor
private func makeModel(installed: Bool = true) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskByMeaning-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F316.\(UUID().uuidString)")!)
    model.isAskEmbeddingModelInstalled = { installed }
    model.refreshRuntime()
    return model
}

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text)
}

private actor Calls {
    var passageRuns = 0
    func countPassageRun() { passageRuns += 1 }
}

/// "pricing"-flavoured texts point one way, everything else the other.
private func fakeVector(_ text: String) -> [Float] {
    let pricing = ["pricing", "fifteen percent", "annual plan"].contains { text.lowercased().contains($0) }
    return pricing ? [1, 0] : [0, 1]
}

@MainActor
@Test("A passage that shares no word with the question is found by meaning, beside the keyword hits (F316)")
func paraphraseIsFoundByMeaning() async throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Planning", status: .completed, segments: [
        seg(0, "We agreed fifteen percent off the annual plan."), seg(30, "The offsite moves to May."),
    ]))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    let calls = Calls()
    model.askEmbedder = { texts, kind in
        if kind == .passage { await calls.countPassageRun() }
        return (2, texts.flatMap(fakeVector))
    }

    #expect(model.askMeetings(query: "pricing decision", scope: MeetingScope()).isEmpty, "no keyword overlap at all")
    let found = await model.askMeetingsByMeaning(query: "pricing decision", scope: MeetingScope())
    #expect(found.map(\.snippet) == ["We agreed fifteen percent off the annual plan."])
    #expect(found.first?.timestamp == 0)

    // The index was saved beside the recording and is reused: no second passage run.
    _ = await model.askMeetingsByMeaning(query: "pricing again", scope: MeetingScope())
    #expect(await calls.passageRuns == 1)
    #expect(FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id)
        .appendingPathComponent(SegmentEmbeddings.vectorsFilename).path))

    // A changed transcript makes the saved index stale, so it is rebuilt rather than trusted.
    model.store.upsert(MeetingRecord(id: id, title: "Planning", status: .completed, segments: [seg(0, "Entirely different words now.")]))
    _ = await model.askMeetingsByMeaning(query: "pricing", scope: MeetingScope())
    #expect(await calls.passageRuns == 2)
}

@MainActor
@Test("Without the model, or when it fails, the result is exactly the keyword search (F316)")
func meaningSearchFallsBackToKeywords() async throws {
    let absent = try makeModel(installed: false)
    absent.store.upsert(MeetingRecord(id: UUID(), title: "Pricing sync", status: .completed, segments: [seg(0, "The pricing tiers changed.")]))
    absent.askEmbedder = { _, _ in Issue.record("must not run without the model"); return (0, []) }
    #expect(await absent.askMeetingsByMeaning(query: "pricing", scope: MeetingScope()) == absent.askMeetings(query: "pricing", scope: MeetingScope()))

    let failing = try makeModel()
    failing.store.upsert(MeetingRecord(id: UUID(), title: "Pricing sync", status: .completed, segments: [seg(0, "The pricing tiers changed.")]))
    failing.askEmbedder = { _, _ in throw LocalEmbedderError.unreadableOutput }
    #expect(await failing.askMeetingsByMeaning(query: "pricing", scope: MeetingScope()) == failing.askMeetings(query: "pricing", scope: MeetingScope()))
}

@Test("The Ask view uses the fused search and offers the download with its size (F316)")
func askViewIsWiredToMeaningSearch() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("await model.askMeetingsByMeaning(query: asked, scope: askedScope)"))
    #expect(view.contains("model.installAskEmbeddingModel()"))
    #expect(view.contains("490 MB"))
    // Read raw, not through the Swift stripper: `build-app.sh` comments with `#`, and running a
    // `//` stripper over it would be a no-op dressed up as a guard (F375).
    let build = try String(contentsOf: SourceAssertion.url("Scripts/build-app.sh"), encoding: .utf8)
    #expect(build.contains("embed_local.py") && build.contains("setup-ask-embeddings.sh"))
}

/// The real model, on invented meetings. Off unless asked for:
///     REAL_ASK_EMBEDDINGS=1 swift test --filter realModelFindsParaphrases
@MainActor
@Test("The real search model finds paraphrased questions end to end (F316, real model)",
      .enabled(if: ProcessInfo.processInfo.environment["REAL_ASK_EMBEDDINGS"] == "1"))
func realModelFindsParaphrases() async throws {
    let model = try makeModel(installed: true)
    let english = UUID(), chinese = UUID()
    model.store.upsert(MeetingRecord(id: english, title: "Planning", status: .completed, segments: [
        seg(0, "We agreed fifteen percent off the annual plan starting in March."),
        seg(30, "Let's move the offsite to the second week of May."),
        seg(60, "Dana will own hiring for the platform group from next month."),
        seg(90, "At the current burn the cash lasts until roughly next October."),
    ]))
    model.store.upsert(MeetingRecord(id: chinese, title: "週會", status: .completed, segments: [
        seg(0, "金流廠商沒通過認證，所以發佈時間往後移。"),
        seg(30, "下個月起平台組的徵才由佳怡負責。"),
        seg(60, "所有密碼都要更換，管理員加上實體金鑰。"),
    ]))
    for id in [english, chinese] {
        try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    }
    for (question, expected) in [
        ("how much runway do we have", "At the current burn"),
        ("when is the team getaway", "offsite"),
        ("為什麼上線延後", "金流廠商"),
        ("資安我們打算怎麼做", "所有密碼"),
    ] {
        let started = Date()
        let keyword = model.askMeetings(query: question, scope: MeetingScope()).first?.snippet
        let fused = await model.askMeetingsByMeaning(query: question, scope: MeetingScope())
        print("REAL Q: \(question) | keyword top: \(keyword ?? "—") | fused top: \(fused.first?.snippet ?? "—") | \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        // Top three, not top one: on the measured set the model's recall@1 is 6/10 and @3 is 8/10,
        // and a test that demanded more than the model delivers would only be pinning luck.
        let rank = fused.firstIndex { $0.snippet.contains(expected) }
        print("REAL    expected passage at rank \(rank.map { String($0 + 1) } ?? "—")")
        #expect(rank.map { $0 < 3 } == true)
    }
}

// F331 — the index is only written `if !store.isDegraded` and the recording folder exists, so on a
// degraded or read-only library — a configuration the feature explicitly advertises support for —
// every query re-embedded every in-scope meeting. `runSearch` fires on `.onAppear` and on every
// scope-chip and match-mode change, so that was a multi-second model run per tap.

@MainActor
@Test("A library that cannot keep the index still embeds only once per session (F331)")
func indexIsCachedWhenItCannotBePersisted() async throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Planning", status: .completed, segments: [
        seg(0, "We agreed fifteen percent off the annual plan."), seg(30, "The offsite moves to May."),
    ]))
    // No recording directory: nothing can be written beside a recording that is not there, which is
    // the same state a degraded or read-only library leaves every meeting in.
    let calls = Calls()
    model.askEmbedder = { texts, kind in
        if kind == .passage { await calls.countPassageRun() }
        return (2, texts.flatMap(fakeVector))
    }

    let first = await model.askMeetingsByMeaning(query: "pricing decision", scope: MeetingScope())
    #expect(first.map(\.snippet) == ["We agreed fifteen percent off the annual plan."])
    _ = await model.askMeetingsByMeaning(query: "pricing again", scope: MeetingScope())
    _ = await model.askMeetingsByMeaning(query: "pricing once more", scope: MeetingScope())
    #expect(await calls.passageRuns == 1, "three queries, one model run")
    #expect(!FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id)
        .appendingPathComponent(SegmentEmbeddings.vectorsFilename).path), "and nothing was persisted")

    // An edited transcript no longer matches the cached fingerprint, so it is rebuilt — the cache
    // must not be able to answer with stale vectors.
    model.store.update(id: id) { $0.segments = [seg(0, "We agreed twenty percent off the annual plan.")] }
    _ = await model.askMeetingsByMeaning(query: "pricing decision", scope: MeetingScope())
    #expect(await calls.passageRuns == 2)
}
