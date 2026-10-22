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
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.isAskEmbeddingModelInstalled = { installed }
    model.refreshRuntime()
    return model
}

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text)
}

/// A completed meeting as a transcription leaves it: the text is the rendering of its lines. Lines
/// under empty text are a transcript the user cleared (F837), which Ask rightly finds nothing in.
private func transcribed(id: UUID, title: String, _ segments: [TranscriptSegment]) -> MeetingRecord {
    MeetingRecord(id: id, title: title, status: .completed,
                  transcriptText: TranscriptFormatter.timestamped(segments), segments: segments)
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
    model.store.upsert(transcribed(id: id, title: "Planning", [
        seg(0, "We agreed fifteen percent off the annual plan."), seg(30, "The offsite moves to May."),
    ]))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    let calls = Calls()
    model.askEmbedder = { texts, kind in
        if kind == .passage { await calls.countPassageRun() }
        return (2, texts.flatMap(fakeVector))
    }

    #expect(await model.askMeetings(query: "pricing decision", scope: MeetingScope()).isEmpty, "no keyword overlap at all")
    let found = await model.askMeetingsByMeaning(query: "pricing decision", scope: MeetingScope())
    #expect(found.map(\.snippet) == ["We agreed fifteen percent off the annual plan."])
    #expect(found.first?.timestamp == 0)

    // The index was saved beside the recording and is reused: no second passage run.
    _ = await model.askMeetingsByMeaning(query: "pricing again", scope: MeetingScope())
    #expect(await calls.passageRuns == 1)
    #expect(FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id)
        .appendingPathComponent(SegmentEmbeddings.vectorsFilename).path))

    // A changed transcript makes the saved index stale, so it is rebuilt rather than trusted.
    model.store.upsert(transcribed(id: id, title: "Planning", [seg(0, "Entirely different words now.")]))
    _ = await model.askMeetingsByMeaning(query: "pricing", scope: MeetingScope())
    #expect(await calls.passageRuns == 2)
}

@MainActor
@Test("Without the model, or when it fails, the result is exactly the keyword search (F316)")
func meaningSearchFallsBackToKeywords() async throws {
    let absent = try makeModel(installed: false)
    absent.store.upsert(transcribed(id: UUID(), title: "Pricing sync", [seg(0, "The pricing tiers changed.")]))
    absent.askEmbedder = { _, _ in Issue.record("must not run without the model"); return (0, []) }
    #expect(await absent.askMeetingsByMeaning(query: "pricing", scope: MeetingScope()) == absent.askMeetings(query: "pricing", scope: MeetingScope()))

    let failing = try makeModel()
    failing.store.upsert(transcribed(id: UUID(), title: "Pricing sync", [seg(0, "The pricing tiers changed.")]))
    failing.askEmbedder = { _, _ in throw LocalEmbedderError.unreadableOutput }
    #expect(await failing.askMeetingsByMeaning(query: "pricing", scope: MeetingScope()) == failing.askMeetings(query: "pricing", scope: MeetingScope()))
}

@Test("The Ask view uses the fused search and offers the download with its size (F316)")
func askViewIsWiredToMeaningSearch() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    // Fused from the keyword pass the view already ranked, not a second rank of the query (F538).
    #expect(view.contains("await model.askMeetingsByMeaning(pass, limit: AppModel.askResultLimit)"))
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
    model.store.upsert(transcribed(id: english, title: "Planning", [
        seg(0, "We agreed fifteen percent off the annual plan starting in March."),
        seg(30, "Let's move the offsite to the second week of May."),
        seg(60, "Dana will own hiring for the platform group from next month."),
        seg(90, "At the current burn the cash lasts until roughly next October."),
    ]))
    model.store.upsert(transcribed(id: chinese, title: "週會", [
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
        let keyword = await model.askMeetings(query: question, scope: MeetingScope()).first?.snippet
        let fused = await model.askMeetingsByMeaning(query: question, scope: MeetingScope())
        print("REAL Q: \(question) | keyword top: \(keyword ?? "—") | fused top: \(fused.first?.snippet ?? "—") | \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        // Top three, not top one: on the measured set the model's recall@1 is 6/10 and @3 is 8/10,
        // and a test that demanded more than the model delivers would only be pinning luck.
        let rank = fused.firstIndex { $0.snippet.contains(expected) }
        print("REAL    expected passage at rank \(rank.map { String($0 + 1) } ?? "—")")
        #expect(rank.map { $0 < 3 } == true)
    }
}

/// What each helper run of a first index cost, for `realModelFirstIndexAtThreeGroupSizes`.
private actor RunTimes {
    private(set) var runs: [(passages: Int, seconds: Double)] = []
    func record(_ passages: Int, _ seconds: Double) { runs.append((passages, seconds)) }
}

/// F841 — F538 groups a first index into helper runs of about `askEmbeddingChunkPassages` passages,
/// each saved before the next, and sized the group on two figures nobody had measured with the real
/// helper: ~1.5 s per 2,000 passages and ~0.4 s to start a helper and load the model. This times a
/// first index of an invented library (40 meetings × 150 lines, English and Chinese) at three group
/// sizes, so the start cost falls out of the difference. Off unless asked for, and never beside the
/// user's dictation (the GPU is shared):
///     REAL_ASK_EMBEDDINGS=1 swift test --filter realModelFirstIndexAtThreeGroupSizes
@MainActor
@Test("A first index with the real search model, timed at three group sizes (F841, real model)",
      .enabled(if: ProcessInfo.processInfo.environment["REAL_ASK_EMBEDDINGS"] == "1"))
func realModelFirstIndexAtThreeGroupSizes() async throws {
    let topics = ["the pricing change", "the hiring plan", "the launch date", "the security review", "the vendor contract",
                  "the budget for next quarter", "the customer escalation", "the offsite agenda"]
    let chinese = ["定價調整", "招聘計劃", "上線時間", "資安審查", "供應商合約", "下季度預算", "客戶投訴", "團建安排"]
    for chunk in [500, 2_000, 6_000] {
        let model = try makeModel(installed: true)
        defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
        model.askEmbeddingChunkPassages = chunk
        var ids: [UUID] = []
        for meeting in 0..<40 {
            let id = UUID()
            let lines = (0..<150).map { line -> TranscriptSegment in
                let n = meeting * 150 + line
                let text = n % 3 == 2
                    ? "第\(meeting + 1)次會議第\(line + 1)句：我們討論了\(chinese[n % chinese.count])，下週再確認細節。"
                    : "Meeting \(meeting + 1), line \(line + 1): we went over \(topics[n % topics.count]) and agreed to follow up by week \(line % 12 + 1)."
                return seg(Double(line) * 5, text)
            }
            model.store.upsert(transcribed(id: id, title: "Meeting \(meeting + 1)", lines))
            try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
            ids.append(id)
        }
        let times = RunTimes()
        let real = model.askEmbedder
        model.askEmbedder = { texts, kind in
            let started = SuspendingClock.now
            let result = try await real(texts, kind)
            let elapsed = SuspendingClock.now - started
            if kind == .passage {
                await times.record(texts.count, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            return result
        }
        let pass = try #require(await model.askKeywordPass(query: "when is the launch", scope: MeetingScope()))
        let started = SuspendingClock.now
        _ = await model.askMeetingsByMeaning(pass, limit: 10)
        let total = SuspendingClock.now - started
        let runs = await times.runs
        let totalSeconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        let passages = runs.reduce(0) { $0 + $1.passages }
        print(String(format: "REAL first index, group %d: %d runs, %d passages, %.2f s total, %.2f s in runs; runs: %@",
                     chunk, runs.count, passages, totalSeconds, runs.reduce(0) { $0 + $1.seconds },
                     runs.map { String(format: "%d in %.2f s", $0.passages, $0.seconds) }.joined(separator: ", ")))
        #expect(passages == 6_000, "the first index did not embed every passage once")
        for id in ids {
            #expect(FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id)
                .appendingPathComponent(SegmentEmbeddings.metadataFilename).path))
        }
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
    model.store.upsert(transcribed(id: id, title: "Planning", [
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
    // must not be able to answer with stale vectors. Edited the way the editor edits (F455): only
    // the text changes. This used to assign `segments`, which the editor never does, and so it
    // passed while a real edit left the stale vectors in place.
    model.store.editTranscript(id: id, text: "00:00  We agreed twenty percent off the annual plan.\n00:30  The offsite moves to May.")
    _ = await model.askMeetingsByMeaning(query: "pricing decision", scope: MeetingScope())
    #expect(await calls.passageRuns == 2)
}
