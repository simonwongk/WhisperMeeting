import Foundation
import Testing
@testable import WhisperCore

// F646 — `backupCoordinatorSnapshotsAndPrunes` (and two other tests that call `BackupCoordinator.backUp`
// more than once on one destination) intermittently threw `anotherBackupIsRunning` on a per-test
// UUID temp directory that nothing else could hold.
//
// The cause is in how the lock is RELEASED, not in who acquired it. An advisory `flock` belongs to the
// open file description, and `close(fd)` only releases it when that is the LAST descriptor referring to
// the description. A process that is being spawned on another thread holds a copy of every open
// descriptor — `O_CLOEXEC` closes them at exec, but until then the copy is a live reference. So a
// lock closed while any thread of the app is inside `posix_spawn` stays held by a child that is not
// doing anything with it, and the next `acquire` on the same file reports `EWOULDBLOCK`: "another
// backup is already running". Measured with a probe that re-acquired a just-closed lock while four
// threads spawned `/usr/bin/true`: 500–600 refusals in 20,000 on a quiet Mac, 1,573 with 11 CPU
// hogs running, and none once the release did `flock(LOCK_UN)` first.
//
// `flock(fd, LOCK_UN)` releases the lock for the whole description, whoever else still holds a
// descriptor to it. These tests model the child with a duplicate (and, once, a real child process)
// because the window itself is microseconds wide and cannot be hit on demand.

private func makeFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("A released backup lock is free again even while a duplicate of its descriptor lives on (F646)")
func backupLockIsFreeAfterReleaseWhileADuplicateDescriptorSurvives() throws {
    let folder = try makeFolder("BackupLockDup")
    defer { try? FileManager.default.removeItem(at: folder) }

    let holder = BackupLock.acquire(backupRoot: folder)
    try #require(holder.isHeld)
    let descriptor = try #require(holder.descriptorForTesting)
    // What a thread inside `posix_spawn` holds until the child execs: another reference to the same
    // open file description.
    let duplicate = dup(descriptor)
    try #require(duplicate >= 0)
    defer { close(duplicate) }

    holder.release()

    let next = BackupLock.acquire(backupRoot: folder)
    defer { next.release() }
    #expect(next.isHeld, "the lock stayed held by the surviving duplicate: \(String(describing: next.unavailableReason))")
    #expect(next.unavailableReason == nil)
}

@Test("A released backup lock is free again while a real child process still holds its descriptor (F646)")
func backupLockIsFreeAfterReleaseWhileAChildProcessHoldsIt() throws {
    let folder = try makeFolder("BackupLockChild")
    defer { try? FileManager.default.removeItem(at: folder) }

    let holder = BackupLock.acquire(backupRoot: folder)
    try #require(holder.isHeld)
    let descriptor = try #require(holder.descriptorForTesting)

    // A child that keeps a copy of the descriptor past its exec: `adddup2` to a different number
    // clears FD_CLOEXEC on the copy, which is the state a child is in between the fork and its exec,
    // made to last. It sleeps; the test kills it.
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, descriptor, 9)
    var pid: pid_t = 0
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("120"), nil]
    defer { for pointer in arguments { free(pointer) } }
    let spawned = posix_spawn(&pid, "/bin/sleep", &actions, nil, &arguments, environ)
    try #require(spawned == 0, "could not spawn the stand-in child (errno \(spawned))")
    defer {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    holder.release()

    let next = BackupLock.acquire(backupRoot: folder)
    defer { next.release() }
    #expect(next.isHeld, "the lock stayed held by the child: \(String(describing: next.unavailableReason))")
}

@Test("A released capture lock reads as free while a duplicate of its descriptor lives on (F646)")
func captureLockIsFreeAfterReleaseWhileADuplicateDescriptorSurvives() throws {
    let folder = try makeFolder("CaptureLockDup")
    defer { try? FileManager.default.removeItem(at: folder) }

    let writer = try #require(RecordingCaptureLock.acquire(in: folder))
    let descriptor = try #require(writer.descriptorForTesting)
    let duplicate = dup(descriptor)
    try #require(duplicate >= 0)
    defer { close(duplicate) }

    writer.release()

    // A recovery probe that read this as a live writer would defer the folder's rebuild until the
    // next launch. Safe, but the writer is gone and the probe should say so.
    let probe = RecordingCaptureLock.probe(in: folder)
    guard case .released(let taken) = probe else {
        Issue.record("the writer released its lock but the probe saw \(probe)")
        return
    }
    taken.release()
}

@Test("A released library lease is free again while a duplicate of its descriptor lives on (F646)")
func libraryLeaseIsFreeAfterReleaseWhileADuplicateDescriptorSurvives() throws {
    let root = try makeFolder("LibraryLeaseDup")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = LibraryWriterLock.acquire(root: root)
    try #require(first.lease == .held(realm: "shared"))
    let descriptor = try #require(first.descriptorForTesting)
    let duplicate = dup(descriptor)
    try #require(duplicate >= 0)
    defer { close(duplicate) }

    first.release()

    let second = LibraryWriterLock.acquire(root: root)
    defer { second.release() }
    #expect(second.lease == .held(realm: "shared"), "the lease stayed held by the surviving duplicate")
}
