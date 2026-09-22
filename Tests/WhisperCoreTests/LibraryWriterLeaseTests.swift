import Foundation
import Testing
@testable import WhisperCore

// F190 Task 9 — the single-writer lease. Taken ONCE at launch, never on the save path: measured at
// 14-30 µs, but the point is not the cost, it is that no lock acquisition can ever appear between a
// user's keystroke and their index being durable.
//
// Not holding the lease never makes anything read-only. It publishes an advisory so the app can say
// "another copy of WhisperMeet is open" — and that is all. A lease that could degrade health would
// be a new way to lock a library, which is the harm this whole family of tickets exists to prevent.
//
// Two hazards verified on this machine and encoded below:
//
//   - `flock` attaches to the OPEN FILE DESCRIPTION, so two `open()` calls IN ONE PROCESS genuinely
//     contend: fd1 takes the lock and fd2 gets EWOULDBLOCK. The lease must therefore be one shared
//     handle, or MeetingStore and DictationLogStore would lock each other out of the same library.
//     (This is also what keeps the concurrency tests meaningful in-process — `fcntl(F_SETLK)` is
//     per-process and would have made them vacuous.)
//   - An unopenable shared lock falls back to a per-uid lock and NEVER unlinks the shared one.
//     Unlinking would silently break serialization against a holder that can still open it.
//
// Genuinely red without the fix: `LibraryWriterLock` does not exist.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WriterLease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("A lease is taken, names its realm, and releases idempotently (F190)")
func aLeaseIsTakenAndReleasedIdempotently() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let handle = LibraryWriterLock.acquire(root: root)
    #expect(handle.lease == .held(realm: "shared"))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".writer.lock").path))

    handle.release()
    handle.release()   // idempotent: also called from deinit, so a double release must be harmless

    // The lock FILE persists and is reused. A 0-byte file is not a stale lock — the kernel releases
    // the lock itself on the last close, including after SIGKILL, so there is no such thing as a
    // stale flock to clean up.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".writer.lock").path))

    let second = LibraryWriterLock.acquire(root: root)
    #expect(second.lease == .held(realm: "shared"))
    second.release()
}

@Test("Two handles on one root contend in-process, which is why the lease is shared (F190)")
func twoHandlesOnOneRootContendInProcess() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = LibraryWriterLock.acquire(root: root)
    #expect(first.lease == .held(realm: "shared"))

    // The hazard, demonstrated rather than described. If `MeetingStore` and `DictationLogStore` each
    // called `acquire`, the second would report the library as owned by another process — in the
    // same process.
    let second = LibraryWriterLock.acquire(root: root)
    #expect(second.lease == .heldElsewhere(realm: "shared"))

    first.release()
    second.release()
}

@Test("The shared lease is memoized per root, so two stores never fight for it (F190)")
func theSharedLeaseIsMemoizedPerRoot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let forMeetings = LibraryWriterLock.shared(for: root)
    let forDictation = LibraryWriterLock.shared(for: root)

    #expect(forMeetings === forDictation, "the two stores did not get the same handle")
    #expect(forMeetings.lease == .held(realm: "shared"))

    // Memoized per resolved path, so a symlinked or non-standardised URL for the same directory is
    // the same lease rather than a second one that locks the first out.
    let awkward = root.appendingPathComponent("subdir/..").standardizedFileURL
    #expect(LibraryWriterLock.shared(for: awkward) === forMeetings)
}

@Test("A different root gets its own lease (F190)")
func adifferentRootGetsItsOwnLease() throws {
    let first = try makeRoot()
    let second = try makeRoot()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let a = LibraryWriterLock.shared(for: first)
    let b = LibraryWriterLock.shared(for: second)
    #expect(a !== b)
    #expect(a.lease == .held(realm: "shared"))
    #expect(b.lease == .held(realm: "shared"))
}

@Test(
    "A read-only lock file is still leased, through the O_RDONLY rung (F190)",
    .enabled(if: getuid() != 0)
)
func aReadOnlyLockFileIsStillLeased() throws {
    let root = try makeRoot()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: root.appendingPathComponent(".writer.lock").path
        )
        try? FileManager.default.removeItem(at: root)
    }
    let lock = root.appendingPathComponent(".writer.lock")
    try Data().write(to: lock)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: lock.path)

    // `flock(LOCK_EX)` on a read-only descriptor is legal, so a 0o444 or foreign-owned-but-readable
    // lock still serializes properly rather than falling back.
    let handle = LibraryWriterLock.acquire(root: root)
    #expect(handle.lease == .held(realm: "shared"))
    handle.release()
}

@Test(
    "An unopenable lock falls back per-uid and never unlinks the shared one (F190)",
    .enabled(if: getuid() != 0)
)
func anUnopenableLockFallsBackPerUidWithoutUnlinking() throws {
    let root = try makeRoot()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: root.appendingPathComponent(".writer.lock").path
        )
        try? FileManager.default.removeItem(at: root)
    }
    let lock = root.appendingPathComponent(".writer.lock")
    try Data().write(to: lock)
    // 0o000 returns EACCES for BOTH O_RDWR and O_RDONLY, so both rungs fail and the ladder falls
    // through to a per-uid lock.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lock.path)

    let handle = LibraryWriterLock.acquire(root: root)
    #expect(handle.lease == .held(realm: "uid-\(getuid())"))
    // The shared lock is NOT unlinked. Unlinking it would silently break serialization against any
    // holder that can still open it — we would be locking a file nobody else is looking at.
    #expect(FileManager.default.fileExists(atPath: lock.path))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".writer-\(getuid()).lock").path
    ))
    handle.release()
}

@Test("A lock file is opened close-on-exec, so a helper subprocess cannot inherit it (F190)")
func theLockDescriptorIsCloseOnExec() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // MANDATORY, not a nicety. The app spawns whisper and Qwen helper subprocesses; without
    // O_CLOEXEC a child inherits the descriptor and keeps the library locked after the parent dies —
    // and because the lock is held by a live process, nothing would look stale.
    let handle = LibraryWriterLock.acquire(root: root)
    let descriptor = try #require(handle.descriptorForTesting)
    let flags = fcntl(descriptor, F_GETFD)
    #expect(flags >= 0)
    #expect(flags & FD_CLOEXEC != 0, "the lock descriptor would be inherited by every helper")
    handle.release()
}

@Test("Not holding the lease never makes a library read-only (F190)")
func notHoldingTheLeaseNeverDegradesTheLibrary() throws {
    struct Note: Codable, Equatable { let title: String }
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Somebody else holds the lease for this directory.
    let holder = LibraryWriterLock.acquire(root: root)
    #expect(holder.lease == .held(realm: "shared"))
    let contender = LibraryWriterLock.acquire(root: root)
    #expect(contender.lease == .heldElsewhere(realm: "shared"))

    // The store still loads complete and still saves. The lease is an ADVISORY — it exists so the
    // app can say "another copy of WhisperMeet is open", and for nothing else. A lease that could
    // degrade health would be a brand new way to lock a library, which is the harm this whole family
    // of tickets exists to prevent.
    let store = BackupJSONStore<[Note]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        recordCount: { $0.count }
    )
    _ = try store.save([Note(title: "written without the lease")])
    let loaded = try #require(try store.load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "written without the lease")])

    holder.release()
    contender.release()
}

// F188 item 3's prerequisite — a lease sampled once outlives the rival it described.
//
// `shared(for:)` memoizes for the life of the process. That is right for a lease we HOLD (the open
// descriptor *is* the lease, so re-asking could only lose it) and wrong for every other answer:
// `RecordingFolderLiveness`'s doc comment names the consequence, and F255's recovery gate is where
// it bites, because `AppModel.performStartupRecovery` re-runs mid-session (`AppModel.swift:4976`,
// `:5016`) against a lease sampled at launch. Until something re-asks the kernel, an instance whose
// rival quit half an hour ago still refuses to rebuild the user's own crashed recording.
//
// Red before the fix: `LibraryWriterLock.refresh` does not exist.

@Test("A memoized .heldElsewhere upgrades to .held once the rival releases (F188)")
func aStaleHeldElsewhereUpgradesOnRefresh() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Another copy of the app owns the library when we launch.
    let rival = LibraryWriterLock.acquire(root: root)
    try #require(rival.lease == .held(realm: "shared"))
    try #require(LibraryWriterLock.shared(for: root).lease == .heldElsewhere(realm: "shared"))

    // It quits. The kernel released its flock on the last close — there is no stale lock on disk —
    // but our memoized answer still says otherwise, and that is the defect, not a test artefact.
    rival.release()
    #expect(LibraryWriterLock.shared(for: root).lease == .heldElsewhere(realm: "shared"))

    #expect(LibraryWriterLock.refresh(for: root).lease == .held(realm: "shared"))
    // And the upgrade is durable: the memo now holds the acquired descriptor, so every later
    // `shared(for:)` sees it too. A refresh that only returned a value would leave every existing
    // caller reading the stale one.
    #expect(LibraryWriterLock.shared(for: root).lease == .held(realm: "shared"))
}

@Test("Refreshing a lease we hold returns the same handle and keeps its descriptor (F188)")
func refreshingAHeldLeaseIsANoOp() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let held = LibraryWriterLock.shared(for: root)
    try #require(held.lease == .held(realm: "shared"))
    let descriptor = try #require(held.descriptorForTesting)

    // Identity, not just equality. Re-acquiring here would contend with ourselves (the two-handles
    // test above proves one process's second `open` gets EWOULDBLOCK), so a refresh that did not
    // short-circuit would downgrade a held lease to `.heldElsewhere` against itself — and, worse,
    // replacing the memoized handle would drop the only strong reference to the descriptor that IS
    // the lease.
    let again = LibraryWriterLock.refresh(for: root)
    #expect(again === held)
    #expect(again.descriptorForTesting == descriptor)
}

@Test("A refresh that still finds a rival keeps reporting one (F188)")
func refreshUnderALiveRivalStillReportsHeldElsewhere() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let rival = LibraryWriterLock.acquire(root: root)
    try #require(rival.lease == .held(realm: "shared"))
    try #require(LibraryWriterLock.shared(for: root).lease == .heldElsewhere(realm: "shared"))

    // The counterpart to the upgrade test: a refresh is a question, not a way to take a lock off
    // somebody. `acquire` is non-blocking and never unlinks, so a live holder is still the holder.
    #expect(LibraryWriterLock.refresh(for: root).lease == .heldElsewhere(realm: "shared"))
    #expect(rival.descriptorForTesting != nil, "the rival must still hold its own descriptor")
    rival.release()
}
