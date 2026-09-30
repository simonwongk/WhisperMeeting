import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F401 — the 1 Hz health tick and `handleCaptureInterruption` read `captureDidDie` from the
// MainActor, and that read used to be `captureQueue.sync { _streamDied }`. The capture queue also
// runs the sample handler and all track I/O, including a restart's whole owed padding in ONE block
// (F292 requires that: no sample buffer may land between pieces). Measured on an M3 Pro's internal
// SSD, a read landing during a 5-minute padding waited 394–515 ms across five trials. That is over
// the 250 ms at which Apple's hang reporting counts a main-thread hang. A slow external library
// volume was not measured.
//
// These tests assert ORDER, not time (AGENTS.md forbids time budgets): the capture queue is held the
// way a long padding block holds it, and the read has to come back while the queue is still held.

private struct CaptureDied: Error {}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ entry: String) { lock.lock(); storage.append(entry); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func engine(_ label: String) -> (AudioCaptureEngine, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptureDidDieRead-\(label)-\(UUID().uuidString)", isDirectory: true)
    let engine = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in },
        directory: directory
    )
    return (engine, directory)
}

@Test("Reading captureDidDie does not wait behind a busy capture queue (F401)")
func captureDidDieIsReadWithoutWaitingForTheCaptureQueue() throws {
    let (engine, directory) = engine("held")
    defer { try? FileManager.default.removeItem(at: directory) }
    engine.handleStreamFailure(CaptureDied())

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let readDone = DispatchSemaphore(value: 0)
    let log = OrderLog()
    engine.holdCaptureQueueForTesting(entered: entered, release: release)
    // The queue is otherwise idle, so this returns at once; the bound only stops a broken seam
    // hanging the suite.
    try #require(entered.wait(timeout: .now() + 10) == .success, "the capture queue was never held")

    DispatchQueue.global(qos: .userInitiated).async {
        let died = engine.captureDidDie
        log.append("read \(died)")
        readDone.signal()
    }
    // Not a time budget on the fix: after the fix the read never waits for the queue, so this
    // returns as soon as the reader thread runs. Before it, the read cannot finish until `release`
    // below, so the bound is only what makes the old code FAIL instead of deadlocking the test.
    let readWhileHeld = readDone.wait(timeout: .now() + 10) == .success
    log.append("released")
    release.signal()
    if !readWhileHeld { readDone.wait() }

    #expect(log.entries == ["read true", "released"],
            "a read of captureDidDie from off the queue waited for the capture queue: \(log.entries)")
}

@Test("captureDidDie follows the death flag through a death, a restart and a stop (F401)")
func captureDidDieFollowsEveryWriteOfTheDeathFlag() async throws {
    let (engine, directory) = engine("transitions")
    defer { try? FileManager.default.removeItem(at: directory) }
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 0, microphoneStart: 0)
    #expect(!engine.captureDidDie, "a fresh capture has not died")

    engine.handleStreamFailure(CaptureDied())
    #expect(engine.captureDidDie, "recordStreamDeath")

    try await engine.restartAfterFailure(paddingFrames: 48_000)
    #expect(!engine.captureDidDie, "a restart that came back clears the death")

    engine.handleStreamFailure(CaptureDied())
    engine.resetForTesting()
    #expect(!engine.captureDidDie, "a stop or cancel clears the death")
}

@Test("A restart that fails puts the death back where captureDidDie can see it (F401)")
func captureDidDieSeesTheDeathAFailedRestartPutsBack() async throws {
    struct RestartFailed: Error {}
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptureDidDieRead-failed-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in throw RestartFailed() },
        directory: directory
    )
    engine.handleStreamFailure(CaptureDied())

    await #expect(throws: RestartFailed.self) { try await engine.restartAfterFailure(paddingFrames: 48_000) }
    #expect(engine.captureDidDie, "the restart cleared the death first, and its failure path restores it")
}
