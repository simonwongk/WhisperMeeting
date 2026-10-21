import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F840 — first indexing for search by meaning showed an indeterminate "Preparing…", and each search ran
// its own embedding: a newer search (every Ask, scope tap and return to the tab) cancelled the group in
// flight and started again. Now one AppModel-owned job does the embedding, reports passages done out of
// passages to do, and a search that arrives while it runs waits for it instead of replacing it. Leaving
// Ask still stops it (`pauseAskIndexing`), as before: the model runs on the GPU the user's dictation uses.

/// What the stand-in embedder was asked for, and a gate that holds its first call.
private actor EmbedderLog {
    var passageCalls: [[String]] = []
    var progressSeen: [AppModel.AskIndexingProgress?] = []
    var open = false
    func record(_ texts: [String], _ progress: AppModel.AskIndexingProgress?) {
        passageCalls.append(texts)
        progressSeen.append(progress)
    }
    func release() { open = true }
    var isOpen: Bool { open }
    var embedded: [String] { passageCalls.flatMap { $0 } }
}

@MainActor
private func makeLibrary(meetings count: Int, lines: Int) throws -> (AppModel, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F840-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.isAskEmbeddingModelInstalled = { true }
    model.refreshRuntime()
    var ids: [UUID] = []
    for meeting in 0..<count {
        let id = UUID()
        var segments: [TranscriptSegment] = []
        for line in 0..<lines {
            let start = Double(line) * 5
            segments.append(TranscriptSegment(speaker: nil, start: start, end: start + 4,
                                              text: "Meeting \(meeting) line \(line) on the vendor pricing."))
        }
        model.store.upsert(MeetingRecord(
            id: id, title: "M\(meeting)", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
        ))
        try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
        ids.append(id)
    }
    return (model, root, ids)
}

/// Polls `condition` under a 30 s wall-clock cap and requires it, so a timeout fails as a timeout.
@MainActor
private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(30)
    while !(await condition()), SuspendingClock.now < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(await condition(), "timed out waiting for \(what)")
}

/// The stand-in embedder: records each passage call with the progress the model showed at that
/// moment, holds until released, and stops on cancellation as the real helper's process group does.
private func gatedEmbedder(_ log: EmbedderLog, model: AppModel) -> @Sendable ([String], LocalEmbedder.Kind) async throws -> (dimension: Int, vectors: [Float]) {
    { texts, kind in
        if kind == .passage {
            let progress = await MainActor.run { model.askIndexingProgress }
            await log.record(texts, progress)
            let deadline = SuspendingClock.now + .seconds(60)
            while !(await log.isOpen), SuspendingClock.now < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        try Task.checkCancellation()
        return (2, texts.flatMap { _ in [Float(1), 0] })
    }
}

private func indexWritten(_ model: AppModel, _ id: UUID) async -> Bool {
    await MainActor.run {
        FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id)
            .appendingPathComponent(SegmentEmbeddings.metadataFilename).path)
    }
}

@MainActor
@Test("A search that arrives while another is indexing waits for that job: every passage is embedded once (F840)")
func aSecondSearchJoinsTheRunningJob() async throws {
    let (model, root, ids) = try makeLibrary(meetings: 3, lines: 4)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = EmbedderLog()
    model.askEmbedder = gatedEmbedder(log, model: model)
    let pass = try #require(await model.askKeywordPass(query: "vendor pricing", scope: MeetingScope()))

    let first = Task { await model.askMeetingsByMeaning(pass, limit: 10) }
    try await waitUntil("the first search to start embedding") { await log.passageCalls.count == 1 }
    let second = Task { await model.askMeetingsByMeaning(pass, limit: 10) }
    try await waitUntil("the second search to join the running job") { model.askIndexJobJoins == 1 }
    await log.release()

    let (a, b) = (await first.value, await second.value)
    #expect(!a.isEmpty && !b.isEmpty)
    let embedded = await log.embedded
    #expect(embedded.count == 12, "\(embedded.count) passages embedded for 12")
    #expect(Set(embedded).count == embedded.count, "a passage was embedded twice")
    for id in ids { #expect(await indexWritten(model, id)) }
}

@MainActor
@Test("A search replaced by a newer one no longer stops the indexing it started (F840)")
func cancellingASearchKeepsTheJob() async throws {
    let (model, root, ids) = try makeLibrary(meetings: 3, lines: 4)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = EmbedderLog()
    model.askEmbedder = gatedEmbedder(log, model: model)
    let pass = try #require(await model.askKeywordPass(query: "vendor pricing", scope: MeetingScope()))

    // What `AskMeetingsView.runSearch` does with the search before a newer one.
    let replaced = Task { await model.askMeetingsByMeaning(pass, limit: 10) }
    try await waitUntil("the search to start embedding") { await log.passageCalls.count == 1 }
    replaced.cancel()
    await log.release()
    _ = await replaced.value

    try await waitUntil("the job to finish") { !model.isIndexingForAsk }
    for id in ids { #expect(await indexWritten(model, id), "the replaced search's indexing was thrown away") }
}

@MainActor
@Test("Indexing reports passages done out of passages to do, group by group, and clears when done (F840)")
func indexingReportsDeterminateProgress() async throws {
    let (model, root, _) = try makeLibrary(meetings: 4, lines: 5)
    defer { try? FileManager.default.removeItem(at: root) }
    model.askEmbeddingChunkPassages = 5   // one meeting per helper run
    let log = EmbedderLog()
    await log.release()
    model.askEmbedder = gatedEmbedder(log, model: model)
    let pass = try #require(await model.askKeywordPass(query: "vendor pricing", scope: MeetingScope()))

    _ = await model.askMeetingsByMeaning(pass, limit: 10)

    let seen = await log.progressSeen
    let expected: [AppModel.AskIndexingProgress?] = [
        .init(done: 0, total: 20), .init(done: 5, total: 20), .init(done: 10, total: 20), .init(done: 15, total: 20),
    ]
    #expect(seen == expected)
    #expect(model.askIndexingProgress == nil)
    #expect(!model.isIndexingForAsk)
}

@MainActor
@Test("Leaving Ask stops the indexing job before its next group (F840)")
func pausingStopsTheJob() async throws {
    let (model, root, ids) = try makeLibrary(meetings: 2, lines: 4)
    defer { try? FileManager.default.removeItem(at: root) }
    model.askEmbeddingChunkPassages = 4
    let log = EmbedderLog()
    model.askEmbedder = gatedEmbedder(log, model: model)
    let pass = try #require(await model.askKeywordPass(query: "vendor pricing", scope: MeetingScope()))

    let search = Task { await model.askMeetingsByMeaning(pass, limit: 10) }
    try await waitUntil("the search to start embedding") { await log.passageCalls.count == 1 }
    model.pauseAskIndexing()
    await log.release()
    _ = await search.value

    try await waitUntil("the job to stop") { !model.isIndexingForAsk }
    #expect(await log.passageCalls.count == 1, "the second group ran after the pause")
    #expect(!(await indexWritten(model, ids[1])))
}

@Test("The Ask view stops indexing when it goes away and shows the job's progress (F840)")
func askViewPausesAndShowsProgress() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("model.pauseAskIndexing()"))
    #expect(source.contains("model.askIndexingProgress"))
}
