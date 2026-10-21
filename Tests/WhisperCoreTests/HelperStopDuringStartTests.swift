import Darwin
import Foundation
import Testing
@testable import WhisperCore

// F878 — `evict()` and `shutdown()` terminate, off the engine's queue, only the helper that is
// registered live. A start registers its helper a few statements after `process.run()`, so a stop
// that lands in between found nothing to terminate, and its queued cleanup then waited behind the
// whole start: the model load (seconds for the real helpers, and a download on a first run). Wave 4
// measured it with a scratch race: 15 and 58 of 600 evictions took over 100 ms, the longest the
// whole 300 ms stand-in load.
//
// These tests do not race. `helperStartHookForTesting` runs on the engine's queue inside the
// window, and the test lands the stop there and holds the start until the engine has counted it.
// The stand-in helper never says it is ready and only exits when the test releases it, so a
// stop that has to wait for the load waits until the 30 s cap.
//
// A stop during a start also must not be read by `FallbackDictationEngine` as "the warm helper
// cannot run on this Mac": it moved the session to the batch engine for good, which was already
// true for a stop that landed after registration and would have become true for one before it.

/// Polls `condition` under a 30 s cap and requires it, so a timeout fails as a timeout.
private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(30)
    while !condition(), SuspendingClock.now < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Records its pid, then stays alive and silent — a model load that never ends — until `release`
/// exists or its directory is gone. Exits only when the engine ends it or the test lets it.
private struct ParkedHelper {
    let script: URL
    let pidFile: URL
    let release: URL

    init(in directory: URL) throws {
        script = directory.appendingPathComponent("parked.sh")
        pidFile = directory.appendingPathComponent("helper.pid")
        release = directory.appendingPathComponent("release")
        let text = """
        printf '%s' "$$" > "\(pidFile.path)"
        while [ -d "\(directory.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
    }

    /// nil while the helper has not written its pid (it may be stopped before it does).
    var pid: Int32? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Blocks the calling thread (the engine's queue, inside the hook) until `count()` has moved past
/// `before`, under a 30 s cap; says whether it did.
private func holdUntilCounted(from before: Int, _ count: () -> Int) -> Bool {
    let deadline = SuspendingClock.now + .seconds(30)
    while count() == before, SuspendingClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    return count() != before
}

private func expectStopped<T>(_ result: Result<T, Error>, sourceLocation: SourceLocation = #_sourceLocation) {
    switch result {
    case .success:
        Issue.record("the start succeeded although it was stopped", sourceLocation: sourceLocation)
    case let .failure(error):
        #expect(error is DictationHelperStoppedError, "\(error)", sourceLocation: sourceLocation)
    }
}

@Test("evict() during a helper's start stops it at once instead of waiting out its model load (F878)")
func evictDuringAStartDoesNotWaitForTheModelLoad() async throws {
    let tmp = try temporaryDirectory("F878-evict")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let helper = try ParkedHelper(in: tmp)
    defer { try? Data().write(to: helper.release) } // runs before the directory's cleanup above
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: helper.script, modelDirectory: tmp
    )
    let evicted = Flag()
    let landed = Flag()
    engine.helperStartHookForTesting = { [unowned engine] point in
        guard point == .launched else { return }
        let before = engine.stopRequestCount
        Task.detached {
            await engine.evict()
            evicted.set()
        }
        if holdUntilCounted(from: before, { engine.stopRequestCount }) { landed.set() }
    }

    let warm = Task { try await engine.warmUp() }
    try await waitFor("the eviction to land inside the start") { landed.isSet }
    try await waitFor("evict() to return without the helper's load ever finishing") { evicted.isSet }
    expectStopped(await warm.result)
    if let pid = helper.pid {
        #expect(Darwin.kill(pid, 0) != 0, "the helper was still alive when evict() returned")
    }
}

@Test("shutdown() during a helper's start ends the start at once (F878)")
func shutdownDuringAStartEndsIt() async throws {
    let tmp = try temporaryDirectory("F878-shutdown")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let helper = try ParkedHelper(in: tmp)
    defer { try? Data().write(to: helper.release) }
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: helper.script, modelDirectory: tmp
    )
    engine.helperStartHookForTesting = { [unowned engine] point in
        if point == .launched { engine.shutdown() }
    }
    let finished = Flag()
    let warm = Task {
        defer { finished.set() }
        try await engine.warmUp()
    }
    try await waitFor("the start to end without the helper's load ever finishing") { finished.isSet }
    expectStopped(await warm.result)
}

@Test("The refiner's evict() during its helper's start stops it at once (F878)")
func refineEvictDuringAStartDoesNotWaitForTheModelLoad() async throws {
    let tmp = try temporaryDirectory("F878-refine")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let helper = try ParkedHelper(in: tmp)
    defer { try? Data().write(to: helper.release) }
    let model = tmp.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: model.appendingPathComponent("model.safetensors").path, contents: Data())
    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: helper.script, modelDirectory: model
    )
    let evicted = Flag()
    let landed = Flag()
    engine.helperStartHookForTesting = { [unowned engine] point in
        guard point == .launched else { return }
        let before = engine.stopRequestCount
        Task.detached {
            await engine.evict()
            evicted.set()
        }
        if holdUntilCounted(from: before, { engine.stopRequestCount }) { landed.set() }
    }

    let warm = Task { try await engine.warmUp() }
    try await waitFor("the eviction to land inside the start") { landed.isSet }
    try await waitFor("evict() to return without the helper's load ever finishing") { evicted.isSet }
    expectStopped(await warm.result)
}

/// Counts warm-ups: a fallback that was warmed is the one `FallbackDictationEngine` chose.
private final class CountingEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var warmUps = 0
    var warmUpCount: Int { lock.withLock { warmUps } }
    func warmUp() async throws { lock.withLock { warmUps += 1 } }
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        DictationResult(text: "batch", languageCode: nil)
    }
    func shutdown() {}
}

@Test(
    "An eviction during the warm helper's start does not move the session to the batch engine (F878)",
    arguments: [HelperStartPoint.launched, .registered]
)
func aStopDuringStartIsNotAReasonToFallBack(point: HelperStartPoint) async throws {
    let tmp = try temporaryDirectory("F878-fallback")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let helper = try ParkedHelper(in: tmp)
    defer { try? Data().write(to: helper.release) }
    let warm = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: helper.script, modelDirectory: tmp
    )
    let batch = CountingEngine()
    let engine = FallbackDictationEngine(primary: warm, fallback: batch)
    let landed = Flag()
    warm.helperStartHookForTesting = { [unowned warm] reached in
        guard reached == point else { return }
        let before = warm.stopRequestCount
        Task.detached { await engine.evict() }
        if holdUntilCounted(from: before, { warm.stopRequestCount }) { landed.set() }
    }

    let finished = Flag()
    let warming = Task {
        defer { finished.set() }
        try await engine.warmUp()
    }
    try await waitFor("the eviction to land inside the start") { landed.isSet }
    try await waitFor("the warm-up to end without the helper's load ever finishing") { finished.isSet }
    expectStopped(await warming.result)
    #expect(batch.warmUpCount == 0, "the batch engine was chosen for the session because of an eviction")
}
