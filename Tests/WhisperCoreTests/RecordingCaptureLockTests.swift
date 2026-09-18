import Foundation
import Testing
@testable import WhisperCore

// F297 — a per-folder capture lock, so "is this folder's writer alive" is answered by the kernel
// rather than inferred from who holds the library-wide lease.
//
// The mechanism is the library lease's (F190): an advisory `flock` on an open descriptor, which the
// kernel releases on the last close — including after SIGKILL — so a lock that is free means the
// process that took it is gone, and there is no such thing as a stale one. What is new is only
// where it lives (the recording folder) and what it is asked (this folder, not this library).

private func makeFolder(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("A folder nobody has ever captured into has no lock file, and says so (F297)")
func untouchedFolderHasNoLockFile() throws {
    // The distinction that keeps old-build captures safe: a folder written by a build that never
    // took the lock is NOT "free", it is unknown, and the caller falls back to the lease gate.
    let directory = try makeFolder("CaptureLockNone")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(RecordingCaptureLock.probe(in: directory) == .noLockFile)
}

@Test("While the writer holds the lock, a probe reports a live writer and takes nothing (F297)")
func heldLockReportsALiveWriter() throws {
    let directory = try makeFolder("CaptureLockHeld")
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try #require(RecordingCaptureLock.acquire(in: directory))
    try withExtendedLifetime(writer) {
        // Two `open()`s in one process genuinely contend on `flock`, which is what makes this
        // testable without a second process — the same fact the library lease's tests rely on.
        #expect(RecordingCaptureLock.probe(in: directory) == .heldByLiveWriter)
        #expect(RecordingCaptureLock.acquire(in: directory) == nil)
    }
}

@Test("Once the writer's descriptor closes, the lock is free and a probe can take it (F297)")
func releasedLockIsFree() throws {
    // `release()` here stands in for the crash: the kernel does the same on the last close of a
    // dead process's descriptors. What the probe hands back is a HELD handle — the sweep keeps it
    // for the rebuild, so a third instance probing the same folder meanwhile sees a live holder.
    let directory = try makeFolder("CaptureLockFree")
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try #require(RecordingCaptureLock.acquire(in: directory))
    writer.release()

    guard case .released(let taken) = RecordingCaptureLock.probe(in: directory) else {
        Issue.record("a released lock must probe as free")
        return
    }
    try withExtendedLifetime(taken) {
        #expect(RecordingCaptureLock.probe(in: directory) == .heldByLiveWriter)
    }
}

@Test("A clean finish removes the lock file, so the folder is not left looking crashed (F297)")
func releaseCanRemoveTheFile() throws {
    let directory = try makeFolder("CaptureLockRemoved")
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try #require(RecordingCaptureLock.acquire(in: directory))
    let path = directory.appendingPathComponent(RecordingCaptureLock.filename).path
    #expect(FileManager.default.fileExists(atPath: path))

    writer.release(removingFile: true)

    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(RecordingCaptureLock.probe(in: directory) == .noLockFile)
    // And `removeIfEmpty` — which a failed start relies on — is not defeated by a leftover.
    #expect(try InterruptedRecordingRecovery.removeIfEmpty(in: directory))
}

@Test("The descriptor is close-on-exec, so a helper subprocess cannot inherit the lock (F297)")
func lockDescriptorIsCloseOnExec() throws {
    // The library lease's hard-won rule: the app spawns whisper and Qwen helpers, and a child that
    // inherits the descriptor holds the folder "live" after the parent dies — and since it is held
    // by a live process, nothing could ever call it stale.
    let directory = try makeFolder("CaptureLockCloexec")
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try #require(RecordingCaptureLock.acquire(in: directory))
    let descriptor = try #require(writer.descriptorForTesting)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
}

// MARK: - the decision, as a pure function of the two facts

@Test("A live writer is refused whatever the lease says (F297)")
func liveWriterIsAlwaysRefused() {
    for lease in [
        StoreWriterLease.held(realm: "shared"), .heldElsewhere(realm: "shared"),
        .unavailable(reason: "x"), .unmanaged,
    ] {
        #expect(
            !InterruptedRecordingRecovery.mayRebuild(folder: .heldByLiveWriter, lease: lease),
            "\(lease)"
        )
    }
}

@Test("A folder whose writer is provably gone may be rebuilt even while another instance is open (F297)")
func provablyDeadWriterMayBeRebuiltUnderARivalLease() throws {
    // The ticket's scenario: B crashed mid-recording and relaunches while A is still open. A holds
    // the lease and has never seen B's folder; B's lock is free because B's process died. That is
    // the folder F255's library-wide refusal kept waiting, and it is exactly the one the lock can
    // vouch for.
    let directory = try makeFolder("CaptureLockRival")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try #require(RecordingCaptureLock.acquire(in: directory))
    writer.release()
    let probe = RecordingCaptureLock.probe(in: directory)
    guard case .released = probe else {
        Issue.record("expected a free lock")
        return
    }
    #expect(InterruptedRecordingRecovery.mayRebuild(folder: probe, lease: .heldElsewhere(realm: "shared")))
}

@Test("Without a lock file, or without flock, the lease gate decides as before (F297)")
func unknownFoldersFallBackToTheLeaseGate() {
    // F279 kept the lease as an additional refusal so that a probe failure degrades to a deferred
    // recovery rather than a re-run of F255. This keeps that: the lock only ever ADDS a refusal
    // (a live writer) or vouches for a folder it has positive evidence about. Everything else is
    // exactly the F255 rule.
    for probe in [RecordingCaptureLock.Probe.noLockFile, .unavailable(reason: "no flock")] {
        #expect(InterruptedRecordingRecovery.mayRebuild(folder: probe, lease: .held(realm: "shared")))
        #expect(InterruptedRecordingRecovery.mayRebuild(folder: probe, lease: .unavailable(reason: "x")))
        #expect(!InterruptedRecordingRecovery.mayRebuild(folder: probe, lease: .heldElsewhere(realm: "shared")))
    }
}
