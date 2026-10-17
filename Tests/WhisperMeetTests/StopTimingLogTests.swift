import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F930 — `captureSettleBound` (10 s) is F292's choice reused for `stopCapture()` by F809, and
// `SCStream.h` documents no bound for a stop. Nothing logged how long a real stop took, so the bound
// could never be checked against one. Every stop Stop and Cancel wait on now logs
// `stream-stop=<ms>ms confirmed=<yes|no|late> outcome=<stopped|failed|expired>`, and a stop that
// outlives the bound logs again, `confirmed=late`, when it finally returns: that second line is the
// one that says how far off the bound is.
//
// Driven through the injected stop (F929's seam) and F809's injected deadline, so no test waits out
// the bound. The lines are caught through `stopTimingLinesForTesting`, the same text the logger gets.

private actor StopLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

private struct StopRefused: Error {}

private func matches(_ line: String, confirmed: String, outcome: String) -> Bool {
    line.wholeMatch(of: #/stream-stop=(\d+)ms confirmed=(\w+) outcome=(\w+)/#).map {
        $0.2 == confirmed && $0.3 == outcome
    } ?? false
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F930-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Polls `log` until it holds `count` lines or 30 s pass.
private func waitForLines(_ log: LineLog, count: Int) async throws -> [String] {
    let deadline = Date().addingTimeInterval(30)
    while log.lines.count < count, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    return log.lines
}

@Test("A Stop whose stopCapture returns logs how long it took, confirmed (F930)")
func aConfirmedStopLogsItsTime() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: nil,
        startingCapture: { _, _, _ in }, directory: directory
    )
    let log = LineLog()
    engine.stopTimingLinesForTesting = { log.append($0) }
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)

    _ = try await engine.stop()

    let lines = log.lines
    #expect(lines.count == 1, "\(lines)")
    #expect(lines.first.map { matches($0, confirmed: "yes", outcome: "stopped") } == true, "\(lines)")
}

@Test("A stop that outlives the bound logs the expiry, then its real time when it returns (F930)")
func aLateStopLogsTwice() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let hung = StopLatch()
    let bound = StopLatch()
    defer { Task { await hung.open(); await bound.open() } }
    let engine = AudioCaptureEngine(
        stoppingCapture: { await hung.wait() }, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, directory: directory
    )
    engine.stopCaptureDeadlineForTesting = { await bound.wait() }
    let log = LineLog()
    engine.stopTimingLinesForTesting = { log.append($0) }

    let cancelled = LineLog()
    Task {
        await engine.cancel()
        cancelled.append("done")
    }
    await bound.open()
    let afterExpiry = try await waitForLines(log, count: 1)
    try #require(afterExpiry.count == 1, "the expired stop logged nothing: \(afterExpiry)")
    #expect(matches(afterExpiry[0], confirmed: "no", outcome: "expired"), "\(afterExpiry)")
    try #require(try await waitForLines(cancelled, count: 1) == ["done"], "the Cancel never returned")

    await hung.open()
    let afterReturn = try await waitForLines(log, count: 2)
    try #require(afterReturn.count == 2, "the late return logged nothing: \(afterReturn)")
    #expect(matches(afterReturn[1], confirmed: "late", outcome: "stopped"), "\(afterReturn)")
}

@Test("A stop that throws logs its time, unconfirmed (F930)")
func aFailedStopLogsItsTime() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AudioCaptureEngine(
        stoppingCapture: { throw StopRefused() }, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, directory: directory
    )
    let log = LineLog()
    engine.stopTimingLinesForTesting = { log.append($0) }

    await engine.cancel()

    let lines = log.lines
    #expect(lines.count == 1, "\(lines)")
    #expect(lines.first.map { matches($0, confirmed: "no", outcome: "failed") } == true, "\(lines)")
}
