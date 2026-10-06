import Foundation

/// The Cancel button's flag for a Correct Toward Vocabulary pass (F536).
///
/// The pass runs on GCD worker threads (`GlossaryCorrector` fans segments out with
/// `concurrentPerform`), where Swift task cancellation cannot be seen, so it polls this instead —
/// once per segment. Set from the main actor, read from any thread.
final class GlossaryPassCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
