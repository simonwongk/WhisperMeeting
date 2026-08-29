import Foundation

/// How one dictation's refinement ended. Persisted into the dictation log as a plain string
/// (`DictationLogEntry.refinement`) — persist the `rawValue`, never this enum, per the
/// persisted-schema rules (lenient forward decoding).
public enum DictationRefinement: String, Sendable, Equatable {
    case refined
    case skipped      // policy skip: empty or too long
    case rawBusy      // a previous dictation's abandoned generation still occupies the engine
    case rawTimeout   // the model missed the budget; raw delivered at the deadline
    case rawRejected  // the model answered but the guardrails refused its output
    case rawError     // the engine failed (helper crash, runtime missing, decode error)
}

/// The text to deliver (always safe to paste — raw on every failure path) plus how it was decided.
public struct RefineAttempt: Sendable, Equatable {
    public let text: String
    public let outcome: DictationRefinement
    public init(text: String, outcome: DictationRefinement) {
        self.text = text
        self.outcome = outcome
    }
}

/// A resident process that can rewrite one dictation. `WarmRefineEngine` is the real one; tests
/// substitute fakes.
public protocol DictationRefineEngine: Sendable {
    func warmUp() async throws
    func refine(_ request: RefineRequest) async throws -> String
    func shutdown()
}

/// The controller-facing seam: everything Quick Dictation needs from refinement, fakeable in
/// `WhisperMeetTests` without a model.
public protocol DictationTextRefining: Sendable {
    func warmUp() async
    func attempt(text: String, languageCode: String?) async -> RefineAttempt
    func shutdown()
}

/// Races the refine engine against `DictationRefinePolicy`'s budget and applies its guardrails.
/// Never blocks delivery: every path returns *some* text, raw on any doubt.
///
/// Concurrency contract: `inFlight` stays true until the engine's serialized request fully
/// completes — including after a timeout abandons its result — and a busy refiner answers
/// `.rawBusy` without touching the engine. Because the engine serializes requests on one queue,
/// this flag is what keeps an abandoned reply from ever being read as the answer to a later
/// request (no request ids needed on the wire).
public actor DictationRefiner: DictationTextRefining {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let engine: any DictationRefineEngine
    private let sleep: Sleep
    private var inFlight = false

    public init(
        engine: any DictationRefineEngine,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.sleep = sleep
    }

    public func warmUp() async {
        try? await engine.warmUp()
    }

    nonisolated public func shutdown() {
        engine.shutdown()
    }

    public func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        guard !inFlight else { return RefineAttempt(text: text, outcome: .rawBusy) }
        guard case let .attempt(budget) = DictationRefinePolicy.decision(for: text) else {
            return RefineAttempt(text: text, outcome: .skipped)
        }
        inFlight = true
        let request = RefineRequest(
            text: text,
            systemPrompt: DictationRefinePrompt.system(languageCode: languageCode),
            maxTokens: DictationRefinePolicy.maxOutputTokens
        )
        let engine = self.engine
        let work = Task { try await engine.refine(request) }
        // Whatever the race below decides, the engine slot frees only when the request itself
        // finishes — that is the busy-skip guarantee.
        Task { [work] in
            _ = try? await work.value
            await self.clearInFlight()
        }

        // First-wins race. NOT a task group: `withTaskGroup` awaits all of its children before
        // returning, and awaiting `work.value` is not cancellation-interruptible — a group-based
        // race therefore blocks until the engine call finishes, which is exactly the wait the
        // budget exists to prevent. The losing task below simply fails to claim and returns.
        enum RaceResult: Sendable { case finished(Result<String, Error>), timedOut }
        let winner = RaceWinner()
        let sleep = self.sleep
        let raced = await withCheckedContinuation { (continuation: CheckedContinuation<RaceResult, Never>) in
            Task {
                let result: RaceResult
                do { result = .finished(.success(try await work.value)) }
                catch { result = .finished(.failure(error)) }
                if winner.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await sleep(budget)
                if winner.claim() { continuation.resume(returning: .timedOut) }
            }
        }

        switch raced {
        case let .finished(.success(output)):
            if let accepted = DictationRefinePolicy.acceptedOutput(output, input: text) {
                return RefineAttempt(text: accepted, outcome: .refined)
            }
            return RefineAttempt(text: text, outcome: .rawRejected)
        case .finished(.failure):
            return RefineAttempt(text: text, outcome: .rawError)
        case .timedOut:
            return RefineAttempt(text: text, outcome: .rawTimeout)
        }
    }

    // Deliberately `async`: the completion Task above may or may not inherit this actor's
    // isolation depending on compiler inference, and a synchronous actor method would make the
    // `await` at the call site "redundant" in one mode — which the release gate's
    // warnings-as-errors turns into a build failure.
    private func clearInFlight() async {
        inFlight = false
    }
}

/// Lets exactly one of two racing tasks resume a shared continuation; the loser's `claim()`
/// returns false and it walks away.
private final class RaceWinner: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
