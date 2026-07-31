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
    try await Task.sleep(for: .milliseconds(10))

    #expect(timeout.didFire)
}
