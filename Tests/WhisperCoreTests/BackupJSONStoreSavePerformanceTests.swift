import Foundation
import Testing
@testable import WhisperCore

/// Shaped like the real index, which is what the decode cost actually tracks: 2.1 MB across only
/// 17 meetings means ~128 KB per meeting of nested per-segment objects, not a few long strings.
/// Thousands of small keyed containers is a completely different decode workload from one big blob.
private struct BenchSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let confidence: Double
    let engine: String
}

private struct BenchMeeting: Codable, Equatable {
    let id: String
    let title: String
    let started: Date
    let durationSeconds: Double
    let tags: [String]
    let segments: [BenchSegment]
}

/// F211 — the ticket's verification clause asks for main-thread time per index save, before and
/// after, at the current index size and at 100 meetings. Opt-in, because it writes tens of MB and
/// its numbers are machine-specific:
///
/// ```
/// F211_MEASURE=1 swift test --disable-sandbox --no-parallel --filter savePathCostBeforeAndAfter
/// ```
///
/// "Before" is reproduced by touching both files between saves, which is exactly the state the old
/// code was always in: every save re-read and re-decoded both copies. No timing is asserted — a
/// threshold here would be a flaky test on someone else's hardware; this exists to be re-run.
@Test(
    "Index save cost, with and without the write memory (F211)",
    .enabled(if: ProcessInfo.processInfo.environment["F211_MEASURE"] == "1")
)
func savePathCostBeforeAndAfter() throws {
    func index(meetings: Int) -> [BenchMeeting] {
        (0..<meetings).map { i in
            BenchMeeting(
                id: UUID().uuidString,
                title: "Meeting \(i) — quarterly planning and review",
                started: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 3600)),
                durationSeconds: 2_800,
                tags: ["planning", "q3", "engineering"],
                // ~45 min of speech at ~4 s per segment, which is what puts 128 KB in a record.
                segments: (0..<700).map { s in
                    BenchSegment(
                        start: Double(s) * 4,
                        end: Double(s) * 4 + 3.8,
                        text: "and then we agreed the release would slip to the following sprint \(s)",
                        confidence: 0.87,
                        engine: "qwen3-asr"
                    )
                }
            )
        }
    }

    for meetings in [17, 100] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F211Bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryURL = directory.appendingPathComponent("meetings.json")
        let backupURL = directory.appendingPathComponent("meetings.backup.json")
        let store = BackupJSONStore<[BenchMeeting]>(primaryURL: primaryURL, backupURL: backupURL)
        let value = index(meetings: meetings)

        try store.save(value)
        let bytes = try Data(contentsOf: primaryURL).count

        // BEFORE: defeat the write memory exactly the way today's code behaves — every save
        // re-reads and re-decodes both files. Touching the files changes their identity.
        var before: [Double] = []
        for _ in 0..<7 {
            try Data(contentsOf: primaryURL).write(to: primaryURL, options: .atomic)
            try Data(contentsOf: backupURL).write(to: backupURL, options: .atomic)
            let t = ContinuousClock.now
            try store.save(value)
            before.append(seconds(since: t))
        }

        // AFTER: consecutive saves, which is what the app actually does.
        var after: [Double] = []
        for _ in 0..<7 {
            let t = ContinuousClock.now
            try store.save(value)
            after.append(seconds(since: t))
        }

        let b = before.sorted()[before.count / 2] * 1000
        let a = after.sorted()[after.count / 2] * 1000
        FileHandle.standardError.write(Data(
            String(format: "    [F211] %3d meetings (%.1f MB index): before %.1f ms -> after %.1f ms (%.1fx)\n",
                   meetings, Double(bytes) / 1e6, b, a, b / max(a, 0.001)).utf8))
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
