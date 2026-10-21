import Foundation
import Testing

/// Polls `condition` — the assertion's own subject, or a precondition the test needs next — until it
/// holds or `timeoutSeconds` pass, then requires it (F957; `WhisperMeetTests` has the main-actor
/// twin). A ceiling, not a budget: a passing run returns the moment the condition holds, and a loaded
/// host only makes the wait longer, never a false failure.
func pollUntil(_ what: String, timeoutSeconds: Double = 30, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(timeoutSeconds)
    while !condition(), SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "timed out waiting for \(what)")
}

/// Polls until `condition` holds or `timeoutSeconds` pass and reports which, for a test that must
/// clean up — kill a stand-in helper it deliberately made unkillable by TERM — before it records the
/// verdict, so a failure cannot leave the helper behind.
func pollUntilOrTimeout(seconds timeoutSeconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = SuspendingClock.now + .seconds(timeoutSeconds)
    while !condition(), SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
