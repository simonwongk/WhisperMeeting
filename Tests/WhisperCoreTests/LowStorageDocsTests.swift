import Foundation
import Testing
@testable import WhisperCore

// F615 — docs/RECOVERY.md and docs/RECORDING_HEALTH.md describe when the low-storage warning is
// raised. Both still said "below 2 GB" after F530 derived the threshold from the recording's own
// size, because F530's commit touched no docs and nothing tied the prose to
// `RecordingHealthMonitor`. Every number these tests look for is computed from the monitor's own
// constants and `RecordingSizeEstimator` at its default (capture) sample rate, so changing the rule
// (the reaction window, the F597 floor, the bytes per second) fails here until the docs follow.

private func repositoryText(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

/// The figures a reader needs, in the units the docs use (decimal MB/KB, whole minutes).
private struct LowStorageFigures {
    let floorMB: Int
    let marginMB: Int
    let mixKBPerSecond: Int
    let windowMinutes: Int
    /// How long a recording runs before the derived term passes the floor.
    let floorGovernsMinutes: Int

    init(sampleRate: Double = RecordingSizeEstimator.defaultSampleRate) {
        let floor = Double(RecordingHealthMonitor.lowStorageFloorBytes)
        let margin = Double(RecordingHealthMonitor.defaultLowStorageMarginBytes(sampleRate: sampleRate))
        let mixPerSecond = Double(RecordingSizeEstimator.mixedBytesPerSecond(sampleRate: sampleRate))
        floorMB = Int((floor / 1_000_000).rounded())
        marginMB = Int((margin / 1_000_000).rounded())
        mixKBPerSecond = Int((mixPerSecond / 1_000).rounded())
        windowMinutes = Int((RecordingHealthMonitor.lowStorageReactionWindow / 60).rounded())
        floorGovernsMinutes = Int(((floor - margin) / mixPerSecond / 60).rounded())
    }
}

@Test("RECOVERY.md's low-storage sentence states the derived threshold and its floor, not a flat 2 GB (F615)")
func recoveryDocDescribesTheDerivedLowStorageThreshold() throws {
    let text = try repositoryText("docs/RECOVERY.md")
    #expect(!text.contains("below 2 GB"))

    let start = try #require(text.range(of: "Before a new meeting, WhisperMeet refuses to start"))
    let end = text.range(of: "\n\n", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
    let paragraph = String(text[start.lowerBound..<end])
    let figures = LowStorageFigures()

    #expect(paragraph.contains("\(figures.floorMB) MB"), "\(paragraph)")
    #expect(paragraph.contains("\(figures.marginMB) MB"), "\(paragraph)")
    #expect(paragraph.contains("\(figures.mixKBPerSecond) KB per recorded second"), "\(paragraph)")
    #expect(paragraph.contains("\(figures.windowMinutes) minutes"), "\(paragraph)")
    #expect(paragraph.contains("\(figures.floorGovernsMinutes) minutes"), "\(paragraph)")
    #expect(paragraph.contains("RecordingHealthMonitor"), "\(paragraph)")
}

@Test("RECORDING_HEALTH.md's low-storage row states the derived threshold and its floor, not a flat 2 GB (F615)")
func recordingHealthDocDescribesTheDerivedLowStorageThreshold() throws {
    let text = try repositoryText("docs/RECORDING_HEALTH.md")
    #expect(!text.contains("below 2 GB"))

    let rows = text.split(separator: "\n").filter { $0.hasPrefix("|") && $0.lowercased().contains("storage") }
    try #require(rows.count == 1, "expected exactly one storage row in the health table, found \(rows)")
    let row = String(rows[0])
    let figures = LowStorageFigures()

    #expect(row.contains("\(figures.floorMB) MB"), "\(row)")
    #expect(row.contains("\(figures.marginMB) MB"), "\(row)")
    #expect(row.contains("\(figures.mixKBPerSecond) KB per recorded second"), "\(row)")
    #expect(row.contains("\(figures.windowMinutes) minutes"), "\(row)")
    #expect(row.contains("RecordingHealthMonitor"), "\(row)")
}
