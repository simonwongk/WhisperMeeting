import Foundation
import os
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F877 — the health tick's free-space read ran on the capture queue every second.
//
// F703 made the read honest (a fresh `URL` per call) and therefore uncached: measured 7.4–24 ms per
// read spaced a second apart, and up to 50 ms in a tight loop, on this Mac (lane X review, and F877's
// re-run of its probe).
// It ran on `captureQueue`, which also writes every captured buffer and which Stop's
// `captureQueue.sync` waits on. `FreeSpaceSampler` moves the read to its own queue and starts one at
// most every ten seconds; the tick only takes a lock and reads the last figure.
//
// These drive the sampler with an injected reader, so no disk is read or filled, and a serial queue
// with a specific key stands in for `captureQueue`, which a test cannot run code on (F402).

/// A reader that records where and how often it ran, and returns `figure`.
private final class RecordingReader: @unchecked Sendable {
    private struct Record { var calls = 0; var ranOnStandIn = false }
    private let record = OSAllocatedUnfairLock(initialState: Record())
    let standInKey: DispatchSpecificKey<Bool>
    let figure: Int64

    init(standInKey: DispatchSpecificKey<Bool>, figure: Int64) {
        self.standInKey = standInKey
        self.figure = figure
    }

    var read: @Sendable (URL) -> Int64? {
        { [self] _ in
            let onStandIn = DispatchQueue.getSpecific(key: standInKey) == true
            record.withLock { $0.calls += 1; $0.ranOnStandIn = $0.ranOnStandIn || onStandIn }
            return figure
        }
    }
    var calls: Int { record.withLock { $0.calls } }
    var ranOnStandIn: Bool { record.withLock { $0.ranOnStandIn } }
}

/// The capture queue's stand-in: serial, and marked so a reader can tell it ran there.
private func captureStandIn() -> (DispatchQueue, DispatchSpecificKey<Bool>) {
    let key = DispatchSpecificKey<Bool>()
    let queue = DispatchQueue(label: "F877.capture-queue-stand-in")
    queue.setSpecific(key: key, value: true)
    return (queue, key)
}

/// Polls `condition` until it holds, with a wall-clock cap far past any real read; the caller
/// `#require`s the result, so an exhausted cap fails as itself rather than as a later claim.
private func eventually(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if condition() { return true }
        usleep(1_000)
    }
    return condition()
}

private let directory = URL(fileURLWithPath: "/F877/session", isDirectory: true)

@Test("The health tick's free-space read runs off the capture queue, and the tick does not wait for it (F877)")
func freeSpaceIsReadOffTheCaptureQueue() throws {
    let (capture, key) = captureStandIn()
    let reader = RecordingReader(standInKey: key, figure: 123_456_789)
    let sampler = FreeSpaceSampler(read: reader.read)

    // The first tick has no figure yet: the read was started elsewhere, not awaited.
    let first = capture.sync { sampler.latest(for: directory, at: 0) }
    #expect(first == nil, "the tick waited for the read: \(String(describing: first))")
    try #require(eventually { reader.calls == 1 }, "the read never ran")
    #expect(!reader.ranOnStandIn, "the read ran on the capture queue")

    // A later tick sees the figure the off-queue read stored.
    try #require(eventually { capture.sync { sampler.latest(for: directory, at: 1) } == 123_456_789 })
}

@Test("A read starts at most once per interval, however often the tick asks (F877)")
func freeSpaceIsReadAtMostOncePerInterval() throws {
    let (capture, key) = captureStandIn()
    let reader = RecordingReader(standInKey: key, figure: 42)
    let sampler = FreeSpaceSampler(interval: 10, read: reader.read)

    _ = capture.sync { sampler.latest(for: directory, at: 100) }
    try #require(eventually { capture.sync { sampler.latest(for: directory, at: 100) } == 42 })
    // Nine more ticks, a second apart: still the one read.
    for second in 101...109 {
        _ = capture.sync { sampler.latest(for: directory, at: TimeInterval(second)) }
    }
    #expect(reader.calls == 1, "\(reader.calls) reads in ten seconds of ticks")
    // Ten seconds after the first, the next tick starts the second read.
    _ = capture.sync { sampler.latest(for: directory, at: 110) }
    try #require(eventually { reader.calls == 2 }, "the second read never started")
    #expect(!reader.ranOnStandIn)
}

@Test("A new session's directory does not inherit the last session's figure (F877)")
func aNewDirectoryStartsOver() throws {
    let (capture, key) = captureStandIn()
    let reader = RecordingReader(standInKey: key, figure: 7)
    let sampler = FreeSpaceSampler(read: reader.read)

    _ = capture.sync { sampler.latest(for: directory, at: 0) }
    try #require(eventually { capture.sync { sampler.latest(for: directory, at: 1) } == 7 })
    // Another recording, possibly on another volume: unknown until its own read lands, and that read
    // starts at once rather than waiting out the interval.
    let other = URL(fileURLWithPath: "/F877/other-session", isDirectory: true)
    #expect(capture.sync { sampler.latest(for: other, at: 2) } == nil)
    try #require(eventually { reader.calls == 2 })
}

@Test("The health tick reads free space through the sampler, never inline (F877)")
func healthTickReadsFreeSpaceThroughTheSampler() throws {
    // The sampler is driven above; this pins that `emitHealthSnapshot` uses it. The tick's timer and
    // the capture session it needs are not drivable headlessly (F402).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let viaSampler = source.contains("sessionDirectory.flatMap { freeSpace.latest(for: $0, at: now) }")
    let inline = source.contains("sessionDirectory.flatMap(Self.availableStorageBytes)")
    #expect(viaSampler, "emitHealthSnapshot does not read through FreeSpaceSampler")
    #expect(!inline, "emitHealthSnapshot reads free space on captureQueue again")
}
