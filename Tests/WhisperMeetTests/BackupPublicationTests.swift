import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice C — three ways a second backup could destroy the first's work, and one lie.
//
// 1. The generation directory was `backupRoot/<now>`, and a run at the same stamp did
//    `try? removeItem(generationDir)` first — deleting a COMPLETE generation to make room for
//    itself. `now` is second-granularity, so "same stamp" is a scheduler coincidence, not a
//    contrivance.
// 2. The final cleanup removed every directory without a completion marker. A concurrently
//    running backup's generation has no marker yet, so run A's cleanup deleted run B's
//    in-flight generation out from under it.
// 3. `prunedGenerations` reported everything it intended to remove, using `try?` to remove it.
//    A failed removal was reported as pruned — the summary claimed a state it had not reached.
//
// The fix is an exclusive lock plus staged publication. Note the lock REFUSES rather than failing
// open, which is the opposite of `InterruptedRecordingRecovery`'s lease, and deliberately: there,
// refusing would permanently disable recovery on a volume without `flock`; here, refusing costs
// one retry and the alternative is a corrupt backup.

private func makeLibrary(_ label: String) throws -> (root: URL, source: URL, destination: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupPub-\(label)-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("meetings".utf8).write(to: source.appendingPathComponent("meetings.json"))
    return (root, source, destination)
}

private func backupRoot(in destination: URL) -> URL {
    destination.appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
}

@Test("A second backup at the same stamp does not destroy the first's completed generation")
func sameStampDoesNotDestroyACompleteGeneration() throws {
    let (root, source, destination) = try makeLibrary("stamp")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try BackupCoordinator.backUp(source: source, destination: destination, now: 100, retain: 5)
    let generation = backupRoot(in: destination).appendingPathComponent(first.generation, isDirectory: true)
    try #require(FileManager.default.fileExists(
        atPath: generation.appendingPathComponent(BackupCoordinator.completionMarker).path
    ))

    // Same stamp again. Whatever it does, it must not leave the first generation destroyed or
    // half-present: a completed backup is the thing the user is relying on.
    _ = try? BackupCoordinator.backUp(source: source, destination: destination, now: 100, retain: 5)

    #expect(FileManager.default.fileExists(
        atPath: generation.appendingPathComponent(BackupCoordinator.completionMarker).path
    ), "the completed generation must survive a same-stamp rerun")
    #expect(FileManager.default.fileExists(
        atPath: generation.appendingPathComponent("meetings.json").path
    ))
}

@Test("A backup refuses while another one holds the destination")
func concurrentBackupIsRefused() throws {
    let (root, source, destination) = try makeLibrary("lock")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: backupRoot(in: destination), withIntermediateDirectories: true)

    // Another run owns the destination. Acquired directly, as the real one does.
    let holder = BackupLock.acquire(backupRoot: backupRoot(in: destination))
    try #require(holder.isHeld)

    var refused = false
    do {
        _ = try BackupCoordinator.backUp(source: source, destination: destination, now: 200, retain: 5)
    } catch BackupCoordinatorError.anotherBackupIsRunning {
        refused = true
    }
    withExtendedLifetime(holder) {}
    #expect(refused, "a concurrent backup must refuse rather than race the first")

    // And refusing left nothing behind that could be mistaken for a backup.
    let contents = (try? FileManager.default.contentsOfDirectory(
        atPath: backupRoot(in: destination).path
    )) ?? []
    #expect(!contents.contains("200"))
}

@Test("Once the holder releases, a backup proceeds")
func releasedLockAllowsTheNextBackup() throws {
    let (root, source, destination) = try makeLibrary("release")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: backupRoot(in: destination), withIntermediateDirectories: true)

    let holder = BackupLock.acquire(backupRoot: backupRoot(in: destination))
    try #require(holder.isHeld)
    holder.release()

    // The counterpart: the lock must not be a permanent refusal. A backup feature that stops
    // working after one run is worse than one that races.
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 300, retain: 5)
    #expect(summary.verified)
}

@Test("An abandoned staging directory is cleaned up and never counted as a backup")
func abandonedStagingIsNotABackup() throws {
    let (root, source, destination) = try makeLibrary("staging")
    defer { try? FileManager.default.removeItem(at: root) }
    let backups = backupRoot(in: destination)
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    // What a crashed run leaves: a staging directory with no completion marker. Under the lock,
    // any staging directory is definitionally abandoned — the holder is the only one who could
    // own it — which is what makes removing it safe rather than a race.
    let abandoned = backups.appendingPathComponent(".staging-abandoned", isDirectory: true)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: abandoned.appendingPathComponent("meetings.json"))

    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 400, retain: 5)

    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(summary.generation == "400")
    // The abandoned bytes were never a generation, so they are not in the prune report either.
    #expect(summary.prunedGenerations.isEmpty)
}

@Test("Prune reports what it removed, not what it intended to remove")
func pruneReportsOnlyRealRemovals() throws {
    let (root, source, destination) = try makeLibrary("prune")
    defer { try? FileManager.default.removeItem(at: root) }

    for stamp in [1, 2, 3] {
        _ = try BackupCoordinator.backUp(source: source, destination: destination, now: stamp, retain: 9)
    }
    // Retain one: two of the three older generations should go.
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 4, retain: 1)
    #expect(summary.prunedGenerations.count == 3)
    for pruned in summary.prunedGenerations {
        #expect(!FileManager.default.fileExists(
            atPath: backupRoot(in: destination).appendingPathComponent(pruned).path
        ), "\(pruned) was reported pruned but is still on disk")
    }
}

@Test("A generation the prune could not remove is not claimed as pruned")
func unremovablePruneTargetIsNotClaimed() throws {
    // The lie, made reproducible. `try?` on the removal with the id reported regardless meant the
    // summary asserted a disk state it had not achieved — the same class of defect as a message
    // that outlives its code, in a return value.
    let (root, source, destination) = try makeLibrary("unremovable")
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try BackupCoordinator.backUp(source: source, destination: destination, now: 10, retain: 9)
    let doomed = backupRoot(in: destination).appendingPathComponent("10", isDirectory: true)
    // Read-only parent: the directory cannot be unlinked from it.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: backupRoot(in: destination).path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: backupRoot(in: destination).path
        )
    }

    let summary = try? BackupCoordinator.backUp(source: source, destination: destination, now: 11, retain: 1)
    if let summary {
        #expect(!summary.prunedGenerations.contains("10"))
    }
    #expect(FileManager.default.fileExists(atPath: doomed.path))
}
