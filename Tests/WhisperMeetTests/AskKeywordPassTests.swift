import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F538 — Ask's keyword ranking tokenized every segment of every in-scope meeting on the main
// actor, on every query, and twice per Ask when search by meaning is installed (measured on a
// synthetic 1,000-meeting library at 6.5–11.9 s a rank). And the meaning index of a large library
// was one all-or-nothing helper run that any newer search cancelled, keeping nothing. No test here
// asserts a duration: what is checked is where the work runs, how often it is redone, and what a
// cancelled run leaves behind.

@MainActor
private func makeModel(installed: Bool) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeywordPass-\(UUID().uuidString)")
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

@MainActor
@discardableResult
private func upsert(_ model: AppModel, _ title: String, _ segments: [TranscriptSegment]) throws -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: title, status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    return id
}

/// Thread observations and per-meeting build counts, written from whatever thread the seams run on.
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var rankedOnMain: [Bool] = []
    private var builtOnMain: [Bool] = []
    private var builds: [UUID: Int] = [:]

    func ranked(onMain: Bool) { lock.withLock { rankedOnMain.append(onMain) } }
    func built(_ id: UUID, onMain: Bool) {
        lock.withLock {
            builtOnMain.append(onMain)
            builds[id, default: 0] += 1
        }
    }
    var ranks: [Bool] { lock.withLock { rankedOnMain } }
    var buildThreads: [Bool] { lock.withLock { builtOnMain } }
    func builds(of id: UUID) -> Int { lock.withLock { builds[id] ?? 0 } }
}

@MainActor
private func observe(_ model: AppModel) -> Observations {
    let seen = Observations()
    model.askTermIndexBuilder = { meeting in
        seen.built(meeting.id, onMain: Thread.isMainThread)
        return MeetingTermIndex(meeting)
    }
    model.askKeywordRanker = { query, corpus, limit in
        seen.ranked(onMain: Thread.isMainThread)
        return MeetingRetrieval.rank(query: query, in: corpus, limit: limit)
    }
    return seen
}

@MainActor
@Test("Ask splits up and ranks the library off the main thread (F538)")
func keywordPassRunsOffTheMainThread() async throws {
    let model = try makeModel(installed: false)
    try upsert(model, "Pricing", [seg(0, "We agreed fifteen percent off the annual plan."), seg(30, "Pricing tiers change in May.")])
    try upsert(model, "Offsite", [seg(0, "The offsite moves to May.")])
    let seen = observe(model)

    let results = await model.askMeetings(query: "pricing tiers", scope: MeetingScope())

    #expect(results.map(\.snippet) == ["Pricing tiers change in May."])
    #expect(seen.ranks == [false], "ranked once, and not on the main thread")
    #expect(seen.buildThreads == [false, false], "each meeting split up once, and not on the main thread")
}

@MainActor
@Test("Each meeting is split up once per version of its text, and a hand edit is a new version (F538, F455)")
func keywordIndexIsBuiltOncePerTextVersion() async throws {
    let model = try makeModel(installed: false)
    let pricing = try upsert(model, "Pricing", [seg(0, "We agreed fifteen percent off the annual plan.")])
    let offsite = try upsert(model, "Offsite", [seg(0, "The offsite moves to May.")])
    let seen = observe(model)

    _ = await model.askMeetings(query: "annual plan", scope: MeetingScope())
    _ = await model.askMeetings(query: "offsite", scope: MeetingScope())
    #expect(await model.askMeetings(query: "fifteen", scope: MeetingScope()).count == 1)
    #expect(seen.builds(of: pricing) == 1)
    #expect(seen.builds(of: offsite) == 1)

    // The editor changes only the text (F455), so that is what the cache must notice.
    model.store.editTranscript(id: pricing, text: "00:00  We agreed twenty percent off the annual plan.")
    #expect(await model.askMeetings(query: "fifteen", scope: MeetingScope()).isEmpty)
    let edited = await model.askMeetings(query: "twenty", scope: MeetingScope())
    #expect(edited.map(\.snippet) == ["We agreed twenty percent off the annual plan."])
    #expect(seen.builds(of: pricing) == 2)
    #expect(seen.builds(of: offsite) == 1)
}

private actor EmbedderCalls {
    private(set) var passageRuns = 0
    private(set) var passages: [[String]] = []
    func startPassageRun(_ texts: [String]) -> Int {
        passageRuns += 1
        passages.append(texts)
        return passageRuns
    }
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

@MainActor
@Test("Indexing for search by meaning saves each chunk as it finishes, so a cancelled search keeps them (F538)")
func cancelledIndexingKeepsFinishedChunks() async throws {
    let model = try makeModel(installed: true)
    model.askEmbeddingChunkPassages = 1 // one meeting per helper run
    try upsert(model, "One", [seg(0, "Pricing for the first customer.")])
    try upsert(model, "Two", [seg(0, "Pricing for the second customer.")])
    try upsert(model, "Three", [seg(0, "Pricing for the third customer.")])
    let order = model.store.meetings.map(\.id)
    let texts = { (id: UUID) in model.store.meeting(id: id)?.segments.map(\.text) ?? [] }
    let directory = { (id: UUID) in model.store.recordingDirectoryURL(for: id) }

    let calls = EmbedderCalls()
    model.askEmbedder = { texts, kind in
        guard kind == .passage else { return (2, [1, 0]) }
        // The second helper run parks until the search is cancelled, as a real run does until
        // `ProcessGroupRunner` kills it.
        if await calls.startPassageRun(texts) == 2 { try await Task.sleep(nanoseconds: 600_000_000_000) }
        return (2, texts.flatMap { _ in [Float(1), 0] })
    }

    let finished = Flag()
    let search = Task { @MainActor in
        _ = await model.askMeetingsByMeaning(query: "pricing", scope: MeetingScope())
        await finished.set()
    }
    // Wait for the second run to start — or for the search to end, which is the failure.
    let deadline = Date().addingTimeInterval(60)
    while await calls.passageRuns < 2, !(await finished.isSet), Date() < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try #require(await calls.passageRuns >= 2, "the meetings were embedded in one all-or-nothing run")
    search.cancel()
    await search.value

    let modelID = AskEmbeddingRuntime.modelID
    #expect(SegmentEmbeddings.read(from: directory(order[0]), modelID: modelID, texts: texts(order[0])) != nil,
            "the chunk that finished before the cancel was saved")
    #expect(SegmentEmbeddings.read(from: directory(order[1]), modelID: modelID, texts: texts(order[1])) == nil)

    // The next search embeds only what is still missing.
    let resumed = EmbedderCalls()
    model.askEmbedder = { texts, kind in
        if kind == .passage { _ = await resumed.startPassageRun(texts) }
        return (2, texts.flatMap { _ in [Float(1), 0] })
    }
    _ = await model.askMeetingsByMeaning(query: "pricing", scope: MeetingScope())
    #expect(await resumed.passages == [texts(order[1]), texts(order[2])])
}

/// The brace-balanced body after the first `marker`, in a source with comments and literals blanked.
private func body(following marker: String, in source: String) throws -> Substring {
    let start = try #require(source.range(of: marker), "\(marker) is gone from ContentView.swift")
    let open = try #require(source.range(of: "{", range: start.upperBound..<source.endIndex))
    var depth = 1
    var cursor = open.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    return source[open.upperBound..<cursor]
}

@Test("The Ask view ranks by keyword once, in the background, and still drops a replaced query's results (F538)")
func askViewRanksOnceInTheBackground() throws {
    let structure = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8),
        blankStringLiterals: true
    )
    let runSearch = try body(following: "private func runSearch()", in: structure)
    #expect(!runSearch.contains("model.askMeetings("), "a synchronous keyword rank is back on the main actor")
    #expect(runSearch.contains("await model.askKeywordPass(query: asked, scope: askedScope)"))
    // The fused search is handed the keyword pass rather than ranking the query again.
    #expect(runSearch.contains("await model.askMeetingsByMeaning(pass"))
    #expect(runSearch.contains("asked == query"))
    // Leaving the tab cancels the search, so returning does not start a second run beside it.
    #expect(structure.contains(".onDisappear { searchTask?.cancel() }"))
}
