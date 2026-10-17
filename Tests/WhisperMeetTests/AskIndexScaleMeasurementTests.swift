import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F840 — what a search by meaning costs per query once a library's indexes exist, at 10,000 rows
/// (under the session cache's bound) and at 20,000 (over it). Opt-in, because its numbers are this
/// Mac's and it writes ~60 MB of indexes:
///
/// ```
/// F840_MEASURE=1 swift test --disable-sandbox --no-parallel --filter askIndexQueryCostAtScale
/// ```
///
/// A stand-in embedder (384 dimensions, the real model's) answers at once, so the numbers are the
/// app's own work: reading each meeting's index, fingerprinting its text, ranking. The first query
/// builds and saves every index; the later ones are what every Ask, scope tap and return to the tab
/// costs. Nothing about time is asserted (F211's rule); the `#require`s make each number mean what
/// it says.
@MainActor
@Test(
    "Per-query cost of search by meaning at 10k and 20k rows (F840 measurement)",
    .enabled(if: ProcessInfo.processInfo.environment["F840_MEASURE"] == "1")
)
func askIndexQueryCostAtScale() async throws {
    for rows in [10_000, 20_000] {
        let meetings = 100
        let lines = rows / meetings
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("F840-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                             defaults: UserDefaults(suiteName: testSuiteName())!)
        model.isAskEmbeddingModelInstalled = { true }
        model.refreshRuntime()
        for meeting in 0..<meetings {
            let id = UUID()
            var segments: [TranscriptSegment] = []
            for line in 0..<lines {
                let start = Double(line) * 5
                let text = "Meeting \(meeting) line \(line): we went over the pricing review and the launch plan again."
                segments.append(TranscriptSegment(speaker: nil, start: start, end: start + 4, text: text))
            }
            model.store.upsert(MeetingRecord(
                id: id, title: "M\(meeting)", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
                status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
            ))
            try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
        }
        model.askEmbedder = { texts, _ in
            var vectors = [Float](repeating: 0, count: texts.count * 384)
            for position in vectors.indices { vectors[position] = Float(position % 7 + 1) / 10 }
            return (384, vectors)
        }
        let pass = try #require(await model.askKeywordPass(query: "pricing review", scope: MeetingScope()))
        try #require(pass.corpus.count == meetings)
        var timings: [String] = []
        for query in 1...4 {
            let started = Date()
            let results = await model.askMeetingsByMeaning(pass, limit: 10)
            try #require(!results.isEmpty)
            timings.append(String(format: "q%d %.0f ms", query, Date().timeIntervalSince(started) * 1000))
        }
        print("F840 \(rows) rows (\(meetings) meetings x \(lines) lines): " + timings.joined(separator: ", ")
              + "; cached vectors \(model.askIndexCacheVectorCount)")
    }
}
