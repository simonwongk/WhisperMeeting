import Foundation

/// Who holds the right to write this library, as far as we can tell (F190).
///
/// Advisory only. Nothing in this module makes a library read-only because of a lease — that would
/// be a brand new way to lock somebody out of their own meetings, which is the harm this family of
/// tickets exists to prevent. It exists so the app can say "another copy of WhisperMeet is open".
public enum StoreWriterLease: Sendable, Equatable {
    /// We hold it. `"shared"` or `"uid-501"`.
    case held(realm: String)
    /// Another live process holds it.
    case heldElsewhere(realm: String)
    /// No lease could be taken at all — unopenable lock, a volume without `flock`, EMFILE.
    case unavailable(reason: String)
    /// No lease was attempted (tests, fixtures).
    case unmanaged
}

/// An open, flocked descriptor, or the reason there isn't one.
///
/// The lock is held by the OPEN FILE DESCRIPTION, which is why this is a class and why the handle
/// must outlive the call: closing the descriptor releases the lock. The kernel also releases it on
/// the last close — including after `SIGKILL` — so there is no such thing as a stale `flock` to
/// clean up, and the 0-byte lock file left on disk is not a stale lock.
public final class LibraryWriterLeaseHandle: @unchecked Sendable {
    public let lease: StoreWriterLease
    private let lock = NSLock()
    private var descriptor: Int32?

    /// The open descriptor, for tests that need to assert a flag on it. Internal, never public API.
    var descriptorForTesting: Int32? { lock.withLock { descriptor } }

    init(lease: StoreWriterLease, descriptor: Int32?) {
        self.lease = lease
        self.descriptor = descriptor
    }

    /// Idempotent, and called from `deinit` as well.
    public func release() {
        let toClose: Int32? = lock.withLock {
            defer { descriptor = nil }
            return descriptor
        }
        if let toClose { close(toClose) }
    }

    deinit { release() }
}

/// Takes the single-writer lease, once, at launch (F190).
///
/// **Never on the save path.** Measured at 14-30 µs, but the cost is not the reason: no lock
/// acquisition may ever sit between a user's keystroke and their index being durable. `save()` stays
/// synchronous, `await`-free and free of any blocking wait, and this type is simply not called from
/// it.
public enum LibraryWriterLock {
    private static let memo = MemoizedLeases()

    /// Non-blocking. NEVER waits, NEVER unlinks an existing lock file, NEVER throws.
    ///
    /// The ladder, in order:
    ///
    /// 1. `open(O_RDWR|O_CREAT|O_CLOEXEC)` then `flock(LOCK_EX|LOCK_NB)`.
    /// 2. `EWOULDBLOCK` ⇒ `.heldElsewhere("shared")` — somebody live has it.
    /// 3. `EACCES`/`EPERM` on open ⇒ retry `O_RDONLY`. `flock(LOCK_EX)` on a read-only descriptor is
    ///    legal, which covers a `0o444` or foreign-owned-but-readable lock.
    /// 4. Still denied ⇒ create and lease `.writer-<uid>.lock` instead, realm `"uid-<n>"`.
    ///
    /// Rung 4 does **not** unlink the shared lock. Unlinking would silently break serialization
    /// against any holder that can still open it: we would be locking a file nobody else is looking
    /// at, and reporting success.
    public static func acquire(root: URL, io: StoreFileIO = .live) -> LibraryWriterLeaseHandle {
        let shared = root.appendingPathComponent(".writer.lock")

        // `O_CLOEXEC` is MANDATORY. The app spawns whisper and Qwen helper subprocesses, and without
        // it a child inherits the descriptor and holds the library locked after the parent dies —
        // and since the lock is held by a live process, nothing would ever look stale.
        for flags in [O_RDWR | O_CREAT | O_CLOEXEC, O_RDONLY | O_CLOEXEC] {
            let descriptor = open(shared.path, flags, 0o644)
            if descriptor >= 0 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    return LibraryWriterLeaseHandle(
                        lease: .held(realm: "shared"), descriptor: descriptor
                    )
                }
                let failure = errno
                close(descriptor)
                if failure == EWOULDBLOCK {
                    return LibraryWriterLeaseHandle(
                        lease: .heldElsewhere(realm: "shared"), descriptor: nil
                    )
                }
                // `flock` refused for a reason that is not contention — a volume without support,
                // for instance. A per-uid file on the same volume would fail the same way, so stop.
                return LibraryWriterLeaseHandle(
                    lease: .unavailable(reason: "flock failed (errno \(failure))"), descriptor: nil
                )
            }
            guard errno == EACCES || errno == EPERM else {
                return LibraryWriterLeaseHandle(
                    lease: .unavailable(reason: "could not open the lock (errno \(errno))"),
                    descriptor: nil
                )
            }
        }

        // Rung 4. A `0o000` lock returns EACCES for both O_RDWR and O_RDONLY, so both rungs above
        // fell through and the shared file is genuinely unusable by us.
        let realm = "uid-\(getuid())"
        let perUser = root.appendingPathComponent(".writer-\(getuid()).lock")
        let descriptor = open(perUser.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return LibraryWriterLeaseHandle(
                lease: .unavailable(reason: "no usable lock file (errno \(errno))"), descriptor: nil
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            return LibraryWriterLeaseHandle(
                lease: failure == EWOULDBLOCK
                    ? .heldElsewhere(realm: realm)
                    : .unavailable(reason: "flock failed (errno \(failure))"),
                descriptor: nil
            )
        }
        return LibraryWriterLeaseHandle(lease: .held(realm: realm), descriptor: descriptor)
    }

    /// The process-wide lease for one library, memoized by resolved path.
    ///
    /// This is what callers should use. `flock` attaches to the open file description, so two
    /// `open()` calls in ONE process genuinely contend — `MeetingStore` and `DictationLogStore`
    /// calling `acquire` separately would lock each other out of the same library and each report
    /// the other as a rival process. Memoizing on
    /// `resolvingSymlinksInPath().standardizedFileURL.path` means a symlinked or non-standardised
    /// URL for the same directory resolves to the same lease rather than a second one.
    public static func shared(for root: URL) -> LibraryWriterLeaseHandle {
        memo.handle(for: root)
    }

    /// Re-asks the kernel who holds the lease, and adopts the answer (F188).
    ///
    /// `shared(for:)` memoizes for the life of the process. That is right for a lease we HOLD — the
    /// open descriptor *is* the lease, so re-acquiring could only contend with ourselves — and
    /// wrong for every other answer, because `.heldElsewhere` is a fact about one instant that the
    /// app then believes forever. `RecordingFolderLiveness`'s doc comment names the consequence;
    /// F255's recovery gate is where it bites, since `AppModel.performStartupRecovery` re-runs
    /// mid-session after a library recovery and is decided by a lease sampled at launch.
    ///
    /// Three properties, and the first two are what make this safe to add:
    ///
    /// 1. A `.held` lease short-circuits with no syscall and the SAME handle, so the descriptor
    ///    this process depends on can never be dropped or re-contended here.
    /// 2. Every other outcome carries a nil descriptor, so replacing the memoized handle closes
    ///    nothing.
    /// 3. It can only ever turn a refusal into permission or leave it alone. `acquire` is
    ///    non-blocking and never unlinks, so re-asking cannot take a lock off a live holder.
    ///
    /// **Still never on the save path.** Not because of the cost — this is the abnormal path by
    /// construction, and the normal one returns without a syscall — but because F190's rule is that
    /// no lock acquisition may sit between a user's keystroke and their index being durable, and an
    /// instance that reaches here is precisely one that might have to open a file to answer.
    public static func refresh(for root: URL) -> LibraryWriterLeaseHandle {
        memo.refresh(for: root)
    }
}

/// One lease per resolved library path, for the lifetime of the process.
private final class MemoizedLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [String: LibraryWriterLeaseHandle] = [:]

    func handle(for root: URL) -> LibraryWriterLeaseHandle {
        let key = root.resolvingSymlinksInPath().standardizedFileURL.path
        return lock.withLock {
            if let existing = handles[key] { return existing }
            let handle = LibraryWriterLock.acquire(root: root)
            handles[key] = handle
            return handle
        }
    }

    func refresh(for root: URL) -> LibraryWriterLeaseHandle {
        let key = root.resolvingSymlinksInPath().standardizedFileURL.path
        return lock.withLock {
            // The short-circuit is load-bearing, not an optimisation: `flock` attaches to the open
            // file description, so a second `open` in this process gets EWOULDBLOCK and we would
            // report `.heldElsewhere` against ourselves — and overwriting the memo would drop the
            // last strong reference to the descriptor that is the lease.
            if let existing = handles[key], case .held = existing.lease { return existing }
            let attempt = LibraryWriterLock.acquire(root: root)
            handles[key] = attempt
            return attempt
        }
    }
}
