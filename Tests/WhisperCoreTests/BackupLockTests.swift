import Foundation
import Testing
@testable import WhisperCore

// F559 — `BackupLock.acquire` used to report every failure to hold the lock the same way
// (`isHeld: false`, no reason), which `BackupCoordinator` turned into "Another backup to this
// destination is already running" regardless of why. Real contention (`flock` returning
// `EWOULDBLOCK`) is the only case that message is true for; a directory sitting where the lock
// file goes, a read-only remount, or a permissions change are not contention at all, and telling
// the user to "try again when it finishes" wastes their time waiting out something that was never
// happening.

@Test("Acquiring the lock when its path is blocked by a directory is NOT reported as contention (F559)")
func lockBlockedByDirectoryIsNotContention() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupLock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // A directory sitting exactly where the 0-byte lock file goes. `open(O_CREAT|O_RDWR)` on an
    // existing directory fails (EISDIR), never reaching `flock` at all.
    try FileManager.default.createDirectory(
        at: tmp.appendingPathComponent(".backup.lock"), withIntermediateDirectories: true
    )

    let handle = BackupLock.acquire(backupRoot: tmp)
    #expect(!handle.isHeld)
    guard case let .unavailable(code, message) = handle.unavailableReason else {
        Issue.record("expected .unavailable, got \(String(describing: handle.unavailableReason))")
        return
    }
    #expect(code == EISDIR)
    #expect(!message.isEmpty)
}

@Test("Real contention (a live holder) is still reported as .contended (F559)")
func lockContentionIsStillReportedAsContended() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupLock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    let holder = BackupLock.acquire(backupRoot: tmp)
    try #require(holder.isHeld)
    defer { holder.release() }

    let second = BackupLock.acquire(backupRoot: tmp)
    #expect(!second.isHeld)
    #expect(second.unavailableReason == .contended)
}

@Test("An acquired lock reports no unavailable reason")
func acquiredLockHasNoUnavailableReason() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupLock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    let handle = BackupLock.acquire(backupRoot: tmp)
    try #require(handle.isHeld)
    #expect(handle.unavailableReason == nil)
    handle.release()
}
