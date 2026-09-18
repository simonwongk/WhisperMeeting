import Foundation
import Testing
@testable import WhisperCore

private final class FakeRefineEngine: DictationRefineEngine, @unchecked Sendable {
    enum Behavior { case reply(String), fail, hang }
    private let lock = NSLock()
    private var _behavior: Behavior
    private var _refineCount = 0
    /// Continuations waiting for `refine` to actually be ENTERED (F277).
    private var _entryWaiters: [CheckedContinuation<Void, Never>] = []
    var refineCount: Int { lock.withLock { _refineCount } }
    init(_ behavior: Behavior) { _behavior = behavior }
    func warmUp() async throws {}

    /// Returns once `refine` has been entered at least once.
    ///
    /// F277: `refineCount` was being used as a proxy for "the abandoned generation started", and
    /// that proxy is racy. `instantSleep` makes the refiner's deadline fire immediately, so under
    /// load the first `attempt` could return `.rawTimeout` before this engine's `refine` had even
    /// been scheduled — leaving the count at 0. Observed once in a full-suite run alongside a
    /// release build. Waiting on entry asserts what the test means instead of hoping for a
    /// scheduling order the code never promised.
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let alreadyEntered = lock.withLock { () -> Bool in
                if _refineCount > 0 { return true }
                _entryWaiters.append(continuation)
                return false
            }
            if alreadyEntered { continuation.resume() }
        }
    }

    func refine(_ request: RefineRequest) async throws -> String {
        var waiters: [CheckedContinuation<Void, Never>] = []
        let behavior = lock.withLock { () -> Behavior in
            _refineCount += 1
            waiters = _entryWaiters
            _entryWaiters = []
            return _behavior
        }
        // Resumed OUTSIDE the lock: resuming a continuation can run arbitrary code, and doing that
        // while holding `lock` would risk re-entering it.
        for waiter in waiters { waiter.resume() }
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
    // Wait for the abandoned generation to actually START before asserting anything about it
    // (F277). The deadline can fire before `refine` is scheduled, which is not a behaviour change —
    // it is the test racing the runtime.
    await engine.waitUntilEntered()
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

// MARK: - F244: the refiner names the dictation's script

private final class RecordingRefineEngine: DictationRefineEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RefineRequest] = []
    var requests: [RefineRequest] { lock.withLock { _requests } }
    func warmUp() async throws {}
    func refine(_ request: RefineRequest) async throws -> String {
        lock.withLock { _requests.append(request) }
        return request.text
    }
    func shutdown() {}
    func evict() async {}
}

@Test("A Traditional dictation is sent with the Traditional-script prompt (F244)")
func refinerNamesTheScriptItWasGiven() async {
    // The F244 harness saw a Traditional dictation come back Simplified; the guard now refuses
    // that, which makes refinement safe and useless for a Traditional writer. Naming the script
    // in the prompt is what lets it work again — read from the text, so nobody's preference is
    // guessed.
    let engine = RecordingRefineEngine()
    let refiner = DictationRefiner(engine: engine, sleep: neverSleep)
    _ = await refiner.attempt(text: "我們星期二把版本出貨了 倫敦辦公室星期三才收到", languageCode: "zh")
    let sent = engine.requests.first?.systemPrompt ?? ""
    #expect(sent == DictationRefinePrompt.system(languageCode: "zh", script: .traditional), Comment(rawValue: sent))
}

@Test("A Chinese dictation before language detection settles still gets its script named (F244)")
func refinerNamesTheScriptWithoutALanguageCode() async {
    // `languageCode` is nil when the refiner runs before detection settles. The text itself says
    // it is Traditional Chinese, which is a stronger signal than none.
    let engine = RecordingRefineEngine()
    let refiner = DictationRefiner(engine: engine, sleep: neverSleep)
    _ = await refiner.attempt(text: "我們星期二把版本出貨了 倫敦辦公室星期三才收到", languageCode: nil)
    let sent = engine.requests.first?.systemPrompt ?? ""
    #expect(sent == DictationRefinePrompt.system(languageCode: "zh", script: .traditional), Comment(rawValue: sent))
}

@Test("An English dictation's prompt is unchanged by script detection (F244)")
func refinerLeavesEnglishAlone() async {
    let engine = RecordingRefineEngine()
    let refiner = DictationRefiner(engine: engine, sleep: neverSleep)
    _ = await refiner.attempt(text: "we shipped the release on tuesday", languageCode: "en")
    #expect(engine.requests.first?.systemPrompt == DictationRefinePrompt.system(languageCode: "en"))
}

// MARK: - F245: the refiner applies the protected-term guard

@Test("A model reply that renames a vocabulary term is delivered raw as rejected (F245)")
func refinerRefusesATermRename() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply("We shipped the Kestral release.")), sleep: neverSleep)
    let attempt = await refiner.attempt(
        text: "um we shipped the Kestrel release", languageCode: "en", protectedTerms: ["Kestrel"]
    )
    #expect(attempt == RefineAttempt(text: "um we shipped the Kestrel release", outcome: .rawRejected))
}

@Test("The two-argument attempt is the three-argument one with no terms (F245)")
func refinerWithoutTermsIsUnchanged() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply("We shipped the Kestral release.")), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "um we shipped the Kestrel release", languageCode: "en")
    #expect(attempt.outcome == .refined)
}
