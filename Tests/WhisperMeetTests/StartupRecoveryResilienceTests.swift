import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// True on the Nth call, so a test can make exactly one orphan's recovery throw.
private final class ThrowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let throwOn: Int
    init(throwOn: Int) { self.throwOn = throwOn }
    func shouldThrow() -> Bool { lock.withLock { count += 1; return count == throwOn } }
}

private struct RecoveryFailure: Error {}

/// F47 — startup orphan recovery must not abort the whole scan when one folder throws.
@MainActor
@Test("A throwing orphan folder does not block recovery of the others")
func throwingOrphanDoesNotAbortRecovery() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StartupRecoveryResilienceTests-\(UUID().uuidString)")
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Three orphan folders (UUID-named dirs not in the index). Stagger creation so their
    // createdAt sort order is stable and the middle one is processed second.
    for _ in 0..<3 {
        try FileManager.default.createDirectory(
            at: recordings.appendingPathComponent(UUID().uuidString),
            withIntermediateDirectories: true
        )
        try await Task.sleep(for: .milliseconds(20))
    }

    let suite = "WhisperMeet.StartupRecoveryResilienceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    // The second orphan processed throws; the first and third rebuild successfully.
    let gate = ThrowGate(throwOn: 2)
    model.recoverInterruptedRecording = { directory in
        if gate.shouldThrow() { throw RecoveryFailure() }
        return RecoveredRecording(
            recordingURL: directory.appendingPathComponent("meeting.wav"),
            duration: 5,
            source: .existingCapture
        )
    }

    await model.performStartupRecovery()

    // Both non-throwing orphans were recovered into the index; the throwing one was skipped, not
    // allowed to abort the remaining orphans.
    #expect(model.store.meetings.count == 2)
}
