import Foundation

/// Why `acquire` did not return a held lock (F559).
///
/// `flock(LOCK_NB)` failing with `EWOULDBLOCK` is the ONLY case that means "another backup is
/// genuinely running" — every other failure, including `open()` failing before `flock` is ever
/// called, means the lock could not even be attempted: a read-only remount, a permissions change,
/// a directory sitting where the lock file goes, too many open files. Collapsing all of those into
/// "another backup is already running" tells the user to wait for something that is not happening.
public enum BackupLockUnavailableReason: Sendable, Equatable {
    /// Real contention: `flock(LOCK_NB)` reported `EWOULDBLOCK`. The existing message is correct
    /// here and unchanged.
    case contended
    /// `open()` or `flock()` failed for some other reason. `errno` and `strerror(errno)` are
    /// carried so the caller can name the actual reason instead of guessing.
    case unavailable(errno: Int32, message: String)
}

/// An exclusive advisory lock on one backup destination (F191 slice C).
///
/// Two backups into the same destination could destroy each other's work three ways, all verified
/// against the code before this existed: a run at the same second-granularity stamp did
/// `try? removeItem` on the generation directory and would delete a **completed** backup; the
/// final partial-cleanup loop removed every directory without a completion marker, which is
/// exactly what a concurrently running backup's generation looks like; and the two runs raced on
/// the same paths throughout.
///
/// **This REFUSES rather than failing open, which is the opposite of
/// `InterruptedRecordingRecovery`'s lease, and deliberately.** There, refusing would permanently
/// disable recovery on a volume without `flock` — a worse bug than the one being prevented. Here,
/// refusing costs the user one retry, and proceeding risks a corrupt backup they would later trust.
/// The asymmetry is which way the fallback is destructive.
///
/// Held by the open file description, like `LibraryWriterLock`, so the kernel releases it on the
/// last close including after `SIGKILL` — there is no such thing as a stale lock here, and the
/// 0-byte lock file left behind is not one.
public final class BackupLockHandle: @unchecked Sendable {
    public let isHeld: Bool
    /// Set whenever `isHeld` is false; nil when the lock was actually acquired.
    public let unavailableReason: BackupLockUnavailableReason?
    private let lock = NSLock()
    private var descriptor: Int32?

    /// Internal, so a test can model a process that holds a duplicate of the descriptor (F646).
    /// Never public API.
    var descriptorForTesting: Int32? { lock.withLock { descriptor } }

    init(isHeld: Bool, descriptor: Int32?, unavailableReason: BackupLockUnavailableReason? = nil) {
        self.isHeld = isHeld
        self.descriptor = descriptor
        self.unavailableReason = unavailableReason
    }

    /// Idempotent, and called from `deinit` as well.
    ///
    /// Unlocks before it closes (F646): `close` alone releases the lock only if no other copy of
    /// the descriptor exists, and a thread inside `posix_spawn` holds one until its child execs.
    public func release() {
        let toClose: Int32? = lock.withLock {
            defer { descriptor = nil }
            return descriptor
        }
        if let toClose { AdvisoryLockDescriptor.unlockAndClose(toClose) }
    }

    deinit { release() }
}

public enum BackupLock {
    static let fileName = ".backup.lock"

    /// Non-blocking. Never waits, never unlinks an existing lock file, never throws.
    ///
    /// A failure to open the lock file at all reports `isHeld: false`, which makes the caller
    /// refuse. That is the safe direction for a backup: a destination whose lock cannot be created
    /// is one we should not be writing generations into either.
    ///
    /// `unavailableReason` on the returned handle distinguishes WHY (F559): only a real
    /// `EWOULDBLOCK` from `flock` means another backup is actually running. Every other errno —
    /// from `open()` failing before `flock` is ever reached, or from `flock` failing some other
    /// way — is carried as `.unavailable(errno:message:)` so the caller can say what is actually
    /// wrong instead of telling the user to wait out a backup that was never running.
    public static func acquire(backupRoot: URL) -> BackupLockHandle {
        let url = backupRoot.appendingPathComponent(fileName)
        // `O_CLOEXEC` for the same reason as the library lock: the app spawns helper subprocesses,
        // and without it a child inherits the descriptor and holds the destination locked after the
        // parent exits — with no stale-lock recovery possible, because a live process holds it.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            return BackupLockHandle(
                isHeld: false, descriptor: nil,
                unavailableReason: .unavailable(errno: code, message: strerrorMessage(code))
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            let reason: BackupLockUnavailableReason = code == EWOULDBLOCK
                ? .contended
                : .unavailable(errno: code, message: strerrorMessage(code))
            return BackupLockHandle(isHeld: false, descriptor: nil, unavailableReason: reason)
        }
        return BackupLockHandle(isHeld: true, descriptor: descriptor)
    }

    private static func strerrorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
