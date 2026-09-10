import Foundation
import Testing
@testable import WhisperCore

private final class FakeRefineEngine: DictationRefineEngine, @unchecked Sendable {
    enum Behavior { case reply(String), fail, hang }
    private let lock = NSLock()
    private var _behavior: Behavior
    private var _refineCount = 0
    var refineCount: Int { lock.withLock { _refineCount } }
    init(_ behavior: Behavior) { _behavior = behavior }
    func warmUp() async throws {}
    func refine(_ request: RefineRequest) async throws -> String {
        let behavior = lock.withLock { () -> Behavior in
            _refineCount += 1
            return _behavior
        }
        switch behavior {
        case let .reply(text): return text
        case .fail: throw SummarizerError.helperFailed("boom")
        case .hang: while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }
    func shutdown() {}
}

private struct FailingWarmRefineEngine: DictationRefineEngine {
    func warmUp() async throws { throw SummarizerError.helperFailed("unavailable") }
    func refine(_ request: RefineRequest) async throws -> String { request.text }
    func shutdown() {}
}

private actor GatedRefineEngine: DictationRefineEngine {
    private var calls = 0
    private var first: CheckedContinuation<String, Never>?
    private var second: CheckedContinuation<String, Never>?

    func warmUp() async throws {}

    func refine(_ request: RefineRequest) async throws -> String {
        calls += 1
        if calls == 1 {
            return await withCheckedContinuation { first = $0 }
        }
        return await withCheckedContinuation { second = $0 }
    }

    nonisolated func shutdown() {}

    func evict() async {}

    var callCount: Int { calls }

    func finishFirst() {
        first?.resume(returning: "first")
        first = nil
    }

    func finishSecond() {
        second?.resume(returning: "second")
        second = nil
    }
}

private let instantSleep: DictationRefiner.Sleep = { _ in }
private let neverSleep: DictationRefiner.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

@Test("A fast, clean reply is delivered as refined text")
func refinedHappyPath() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply("Hello there.")), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "Hello there.", outcome: .refined))
}

@Test("A guardrail-violating reply falls back to the raw transcript")
func guardrailRejectionFallsBackToRaw() async {
    let essay = String(repeating: "An unrelated essay. ", count: 10)
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply(essay)), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "hello there", outcome: .rawRejected))
}

@Test("An engine error falls back to the raw transcript")
func engineErrorFallsBackToRaw() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.fail), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "hello there", outcome: .rawError))
}

@Test("A missed budget delivers raw at the deadline, and the refiner then reports busy")
func timeoutThenBusy() async {
    let engine = FakeRefineEngine(.hang)
    let refiner = DictationRefiner(engine: engine, sleep: instantSleep)
    let first = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(first == RefineAttempt(text: "hello there", outcome: .rawTimeout))
    // The abandoned generation is still occupying the engine — the next dictation must skip,
    // never queue behind it.
    let second = await refiner.attempt(text: "next words", languageCode: "en")
    #expect(second == RefineAttempt(text: "next words", outcome: .rawBusy))
    #expect(engine.refineCount == 1)
}

@Test("Policy skips (long text) never touch the engine")
func policySkipNeverCallsEngine() async {
    let engine = FakeRefineEngine(.reply("x"))
    let refiner = DictationRefiner(engine: engine, sleep: neverSleep)
    let long = Array(repeating: "word", count: 61).joined(separator: " ")
    let attempt = await refiner.attempt(text: long, languageCode: "en")
    #expect(attempt == RefineAttempt(text: long, outcome: .skipped))
    #expect(engine.refineCount == 0)
}

@Test("An evicted request cannot clear the busy state of a newer request")
func staleCompletionDoesNotClearNewerRequest() async {
    let engine = GatedRefineEngine()
    let refiner = DictationRefiner(engine: engine, sleep: instantSleep)

    let first = await refiner.attempt(text: "first words", languageCode: "en")
    #expect(first.outcome == .rawTimeout)
    for _ in 0..<100 {
        if await engine.callCount >= 1 { break }
        await Task.yield()
    }

    await refiner.evict()
    let second = await refiner.attempt(text: "second words", languageCode: "en")
    #expect(second.outcome == .rawTimeout)
    for _ in 0..<100 {
        if await engine.callCount >= 2 { break }
        await Task.yield()
    }

    // The old request finishes after the new one has taken ownership of the busy flag.
    await engine.finishFirst()
    for _ in 0..<10 { await Task.yield() }
    let third = await refiner.attempt(text: "third words", languageCode: "en")
    #expect(third.outcome == .rawBusy)

    await engine.finishSecond()
}

@Test("A failed optional warm-up reports not-ready so callers can stay on the raw path")
func failedWarmUpReportsNotReady() async {
    let refiner = DictationRefiner(engine: FailingWarmRefineEngine())
    let ready = await refiner.warmUp()
    #expect(ready == false)
}
