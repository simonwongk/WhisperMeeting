import Foundation
import Testing
@testable import WhisperMeet

private final class TimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func record() {
        lock.withLock { fired = true }
    }

    var didFire: Bool {
        lock.withLock { fired }
    }
}

/// Polls the assertion's own subject against a wall-clock cap, rather than sleeping a fixed time.
@MainActor
private func waitUntilFired(_ timeout: TimeoutRecorder) async throws -> Bool {
    let deadline = SuspendingClock.now + .seconds(30)
    while !timeout.didFire, SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    return timeout.didFire
}

@MainActor
@Test("A stuck dictation capture is finalized after its maximum duration")
func watchdogFinalizesStuckCapture() async throws {
    let timeout = TimeoutRecorder()
    let watchdog = DictationCaptureWatchdog(
        timeout: .seconds(120),
        sleep: { _ in },
        onTimeout: timeout.record
    )

    watchdog.arm()

    #expect(try await waitUntilFired(timeout))
}

// F771 — the shape F718 removed from WhisperCore: a closure literal in a default argument is
// compiled into every module that uses the default, and at -Onone two copies of an async closure
// disagreed on their context size and were mispaired by the link. This init is internal, so only a
// `@testable` client could use the default, and nothing did; the default is moved into the body
// anyway, so no copy can exist to be mispaired.

@MainActor
@Test("The capture watchdog's default sleep is written in its init, not in a default argument (F771, F718)")
func theWatchdogsDefaultSleepIsInItsBody() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationCaptureWatchdog.swift")
    let initStart = try #require(source.range(of: "init("), "DictationCaptureWatchdog.init not found")
    let parameters = source[initStart.upperBound...].prefix { $0 != ")" }
    #expect(!parameters.contains("{"), "a closure literal in the init's parameter list: \(parameters)")
    #expect(parameters.contains("sleep: Sleep? = nil"), "\(parameters)")
}

@MainActor
@Test("A capture watchdog built with its default sleep, from the test module, times out through that sleep (F771)")
func theWatchdogsDefaultSleepFires() async throws {
    let timeout = TimeoutRecorder()
    let watchdog = DictationCaptureWatchdog(timeout: .milliseconds(10), onTimeout: timeout.record)

    watchdog.arm()

    #expect(try await waitUntilFired(timeout), "the default sleep never returned")
}
