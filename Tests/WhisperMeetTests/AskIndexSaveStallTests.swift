import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F871 — since F849 each group of the meaning index is saved on the main actor (a save there runs
// wholly before or after a delete of the same meeting). A group is ~2,000 passages, so a group of
// many short meetings saved them all in one stretch: the review estimated ~118 ms for 400 meetings of
// five lines, and `askIndexSaveStallAtScale` below measured the main thread's longest stall at
// 162–167 ms (debug build, three runs) — ten frames of a frozen window during a library's first
// index. The saves stay on the main actor, one meeting at a time, and it is given back between them.

@MainActor
private func makeLibrary(meetings count: Int, lines: Int) throws -> (AppModel, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F871-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.isAskEmbeddingModelInstalled = { true }
    model.refreshRuntime()
    var records: [MeetingRecord] = []
    var ids: [UUID] = []
    for meeting in 0..<count {
        let id = UUID()
        var segments: [TranscriptSegment] = []
        for line in 0..<lines {
            let start = Double(line) * 5
            let text = "Meeting \(meeting) line \(line) about the pricing review."
            segments.append(TranscriptSegment(speaker: nil, start: start, end: start + 4, text: text))
        }
        records.append(MeetingRecord(
            id: id, title: "M\(meeting)", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
        ))
        try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
        ids.append(id)
    }
    for record in records { model.store.upsert(record) }
    // The real model's 384 dimensions, so each file is the size it would be.
    model.askEmbedder = { texts, _ in (384, [Float](repeating: 0.01, count: texts.count * 384)) }
    return (model, root, ids)
}

/// Whether the main actor ran something between two saves, written and read on the main actor.
@MainActor
private final class TurnProbe {
    var savesWithoutATurn = 0
    var saves = 0
    var turnTaken = true
}

@MainActor
@Test("A group of short meetings is saved one meeting at a time, giving the main actor back between them (F871)")
func groupSavesYieldBetweenMeetings() async throws {
    let (model, root, ids) = try makeLibrary(meetings: 40, lines: 5)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = TurnProbe()
    model.askIndexSave = { index, directory in
        // Each save runs on the main actor (F849), so this reads and writes the probe there.
        MainActor.assumeIsolated {
            probe.saves += 1
            if !probe.turnTaken { probe.savesWithoutATurn += 1 }
            probe.turnTaken = false
            // Queued behind this save; it runs only if the main actor is given back before the next.
            Task { @MainActor in probe.turnTaken = true }
        }
        try index.write(to: directory)
    }

    let pass = try #require(await model.askKeywordPass(query: "pricing review", scope: MeetingScope()))
    _ = await model.askMeetingsByMeaning(pass, limit: 10)

    try #require(probe.saves == ids.count, "fixture: \(probe.saves) of \(ids.count) meetings saved")
    #expect(probe.savesWithoutATurn == 0, "\(probe.savesWithoutATurn) saves ran back to back with the main actor held")
    // Every meeting's index is on disk, as before.
    let written = ids.filter {
        FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: $0)
            .appendingPathComponent(SegmentEmbeddings.metadataFilename).path)
    }
    #expect(written.count == ids.count)
}

/// The longest the main thread went without answering, sampled from another thread every 1 ms.
private final class MainThreadStallMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: TimeInterval = 0
    private var running = true

    var longest: TimeInterval { lock.withLock { worst } }

    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = Date().timeIntervalSince(sent)
                lock.withLock { worst = max(worst, waited) }
                usleep(1_000)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}

/// Opt-in, because its numbers are this Mac's: `F871_MEASURE=1 swift test … --filter askIndexSaveStallAtScale`.
/// Asserts nothing about time (F211's rule); prints the longest main-thread stall while 400 meetings of
/// five lines are indexed with a stand-in embedder, so the saves are the main actor's only work.
@MainActor
@Test(
    "The longest main-thread stall while 400 short meetings are indexed (F871 measurement)",
    .enabled(if: ProcessInfo.processInfo.environment["F871_MEASURE"] == "1")
)
func askIndexSaveStallAtScale() async throws {
    for run in 1...3 {
        let (model, root, ids) = try makeLibrary(meetings: 400, lines: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let pass = try #require(await model.askKeywordPass(query: "pricing review", scope: MeetingScope()))
        let meter = MainThreadStallMeter()
        meter.start()
        let started = Date()
        _ = await model.askMeetingsByMeaning(pass, limit: 10)
        let elapsed = Date().timeIntervalSince(started)
        meter.stop()
        let saved = ids.filter {
            FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: $0)
                .appendingPathComponent(SegmentEmbeddings.metadataFilename).path)
        }.count
        print(String(format: "F871 run %d: 400 meetings x 5 lines, longest main-thread stall %.1f ms, index %.0f ms, indexes saved %d",
                     run, meter.longest * 1000, elapsed * 1000, saved))
    }
}
