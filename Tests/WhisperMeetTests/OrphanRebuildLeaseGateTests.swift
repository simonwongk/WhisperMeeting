import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F255 — a second live instance must not rebuild a folder the first one is still writing.
//
// Testing `.heldElsewhere` needs a specific recipe, because there is no seam:
// `MeetingStore.writerLease` is `private(set)` with no setter, and a second `MeetingStore` on the
// same root gets the MEMOIZED handle and so reports `.held`. Acquire the lock FIRST, keep it alive
// with `withExtendedLifetime` (the handle releases in `deinit`), and only then construct the store.
// Do not "solve" this by widening `writerLease` to a settable var.

/// A folder that looks exactly like an interrupted capture: raw tracks, no finalized WAV. This is
/// also exactly what a LIVE capture's folder looks like, which is the whole defect —
/// `meeting.wav` is written only by `AudioCaptureEngine.stop()`.
private func makeLiveLookingCaptureFolder(in root: URL) throws -> URL {
    let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.25, count: 48_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: directory.appendingPathComponent("system-audio.f32"))
    }
    return directory
}

@Test("While another instance holds the lease, the orphan sweep reports nothing to rebuild")
@MainActor
func orphanSweepIsGatedByTheLease() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetLeaseGate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try makeLiveLookingCaptureFolder(in: root)

    // Another instance owns the library.
    let blocker = LibraryWriterLock.acquire(root: root)
    try withExtendedLifetime(blocker) {
        let store = MeetingStore(rootDirectory: root)
        try #require(store.writerLease == .heldElsewhere(realm: "shared"))

        // `orphanedRecordings()` still reports honestly — it is a read-and-report and the gate is
        // deliberately NOT in it. The folder is genuinely there and genuinely unindexed.
        #expect(try store.orphanedRecordings().count == 1)

        // What must be true is that the model refuses to rebuild it.
        #expect(!store.mayRebuildInterruptedRecordings)
    }

    // Nothing was touched: the raw track survives and no rebuild was written.
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-audio.f32").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovered.wav").path))
}

@Test("An instance that owns the library is permitted to rebuild")
@MainActor
func owningInstanceMayRebuild() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetLeaseOwned-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeLiveLookingCaptureFolder(in: root)

    let store = MeetingStore(rootDirectory: root)
    // No rival holder, so this instance holds the lease and the gate opens. The counterpart to the
    // test above: the gate must not be a blanket refusal.
    #expect(store.mayRebuildInterruptedRecordings)
    #expect(try store.orphanedRecordings().count == 1)
}

@Test("A degraded library reports no orphans regardless of the lease")
@MainActor
func degradedLibraryStillReportsNoOrphans() throws {
    // The F187 guard is independent of the F255 gate and must keep working: an index that failed to
    // load makes every folder look orphaned, which is how ten meetings became blank stubs on
    // 2026-08-14.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetLeaseDegraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeLiveLookingCaptureFolder(in: root)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))

    let store = MeetingStore(rootDirectory: root)
    try #require(store.isDegraded)
    // Holds the lease, so the F255 gate is open — and the F187 guard still refuses.
    #expect(store.mayRebuildInterruptedRecordings)
    #expect(try store.orphanedRecordings().isEmpty)
}
