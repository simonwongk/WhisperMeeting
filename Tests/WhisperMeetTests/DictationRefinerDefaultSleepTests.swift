import Foundation
import Testing
import WhisperCore

/// A refine engine that does not answer until `release()`, so a refinement can only end by its
/// budget running out.
private final class HeldRefineEngine: DictationRefineEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func warmUp() async throws {}

    func refine(_ request: RefineRequest) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return request.text
    }

    func shutdown() {
        release()
    }

    /// Lets every held and every later `refine` call return.
    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting.removeAll() }
            return waiting
        }
        held.forEach { $0.resume() }
    }
}

/// F718 — `DictationRefiner`'s default budget sleep runs to completion when the refiner is built
/// from another module, the way `DictationController` builds it.
///
/// The default used to be a closure literal in the public init's default argument. Swift emits a
/// copy of such a closure into every module that uses the default, and at `-Onone` the copies
/// disagreed on their async context size: WhisperCore's needed 144 bytes, the client copies 128.
/// The closure's body and its async function pointer (the record holding that size) are separate
/// weak symbols, and the debug link took the body from WhisperCore and the record from a client.
/// The caller then allocated 128 bytes for a callee that wrote 144, which corrupted the task
/// allocator, and the process aborted with "freed pointer was not the last allocation" as soon as
/// the budget sleep returned. Inspecting the debug app binary found the same pairing.
///
/// Any module other than WhisperCore that uses the default got its own copy. This test sits in the
/// app's test module, beside `DictationController`, which builds its refiner this way. It keeps
/// the default sleep and holds the engine until the attempt returns, so the only way to
/// `.rawTimeout` is through the budget sleep returning. Before the fix the test process aborted
/// there; there is no assertion that can fail first.
@Test("A DictationRefiner built with its default sleep, from another module, times out through that sleep and the process survives it (F718)")
func refinerBuiltWithTheDefaultSleepSurvivesItsBudgetSleep() async throws {
    let engine = HeldRefineEngine()
    // No `sleep:` argument — exactly what DictationController passes.
    let refiner = DictationRefiner(engine: engine)
    let text = "please send the meeting notes to the whole team"
    // A skipped text never starts the budget sleep, and would prove nothing.
    try #require(DictationRefinePolicy.decision(for: text) != .skip)

    let attempt = await refiner.attempt(text: text, languageCode: "en")
    engine.release()

    // The engine was still held, so only the budget sleep's return can have decided this.
    #expect(attempt.outcome == .rawTimeout)
    #expect(attempt.text == text)
}
