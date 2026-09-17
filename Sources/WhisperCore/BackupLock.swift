import Foundation

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
    private let lock = NSLock()
    private var descriptor: Int32?

    init(isHeld: Bool, descriptor: Int32?) {
        self.isHeld = isHeld
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

public enum BackupLock {
    static let fileName = ".backup.lock"

    /// Non-blocking. Never waits, never unlinks an existing lock file, never throws.
    ///
    /// A failure to open the lock file at all reports `isHeld: false`, which makes the caller
    /// refuse. That is the safe direction for a backup: a destination whose lock cannot be created
    /// is one we should not be writing generations into either.
    public static func acquire(backupRoot: URL) -> BackupLockHandle {
        let url = backupRoot.appendingPathComponent(fileName)
        // `O_CLOEXEC` for the same reason as the library lock: the app spawns helper subprocesses,
        // and without it a child inherits the descriptor and holds the destination locked after the
        // parent exits — with no stale-lock recovery possible, because a live process holds it.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return BackupLockHandle(isHeld: false, descriptor: nil) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return BackupLockHandle(isHeld: false, descriptor: nil)
        }
        return BackupLockHandle(isHeld: true, descriptor: descriptor)
    }
}
