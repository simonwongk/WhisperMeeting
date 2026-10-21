import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F789 — since F389, Export Diagnostics reads up to five crash reports of up to 4 MB each and parses
// them, and it did so inside `saveDiagnostics(to:)` on the main actor: the whole app stopped while
// it read. The read is the `diagnosticsCrashReports` seam; it now runs off the main actor.
//
// No clock: the seam holds until the test lets it go, and the test checks, while it holds, that the
// read is not on the main thread and that the main actor still runs the test's own code. The hold
// has a bound only so that a regression fails instead of hanging the suite.

private final class HeldRead: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var _onMainThread: Bool?
    private let release = DispatchSemaphore(value: 0)

    var entered: Bool { lock.withLock { _entered } }
    var ranOnMainThread: Bool? { lock.withLock { _onMainThread } }
    func letGo() { release.signal() }

    func read() -> [CrashReportRecord] {
        lock.withLock {
            _entered = true
            _onMainThread = Thread.isMainThread
        }
        _ = release.wait(timeout: .now() + 20)
        return []
    }
}

@MainActor
@Test("Export Diagnostics reads the crash reports off the main actor, and still saves (F789)")
func diagnosticsCrashReadRunsOffTheMainActor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F789-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let held = HeldRead()
    model.diagnosticsCrashReports = { held.read() }
    let destination = root.appendingPathComponent("diagnostics.json")

    let save = Task { await model.saveDiagnostics(to: destination) }
    // This loop runs on the main actor. If the read held the main actor, the loop could not run
    // until the read gave up, and it would find the read already over.
    let deadline = SuspendingClock.now + .seconds(30)
    while !held.entered, SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(held.entered, "the crash-report read never started")
    #expect(held.ranOnMainThread == false, "the crash reports were read on the main thread")
    #expect(!FileManager.default.fileExists(atPath: destination.path), "the main actor ran while the read was still held")
    held.letGo()
    await save.value

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(model.alertMessage == nil)
}
