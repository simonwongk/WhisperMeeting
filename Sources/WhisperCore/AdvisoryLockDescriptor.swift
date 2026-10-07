import Foundation

/// How a descriptor that holds an advisory `flock` is let go (F646).
///
/// `close(fd)` is NOT "release the lock". An advisory `flock` belongs to the open file description,
/// and `close` releases it only when `fd` was the LAST descriptor referring to that description.
/// Any other copy keeps the lock held. The copy that matters is one the app did not make on
/// purpose: a thread that is inside `posix_spawn` (or `fork`) holds a copy of every descriptor the
/// process has open until the child's `exec` closes the `O_CLOEXEC` ones. `O_CLOEXEC` is therefore
/// necessary and not sufficient: it keeps a helper from inheriting the lock for good, and it does
/// nothing for the interval before the helper execs. During that interval a lock the app has
/// already closed still refuses everyone, including the app's own next `acquire`, with the same
/// `EWOULDBLOCK` a live rival produces.
///
/// That is what made `BackupCoordinator.backUp` report "another backup is already running" for a
/// backup nothing was running: two runs into one destination, one after the other, with the app
/// starting a helper process on another thread in between. A probe that re-acquired a just-closed
/// lock while four threads spawned `/usr/bin/true` was refused 500–600 times in 20,000 on a quiet
/// Mac and 1,573 times with 11 CPU hogs running; the same probe with `LOCK_UN` first was never
/// refused.
///
/// `flock(fd, LOCK_UN)` releases the lock for the whole description, whoever else still holds a
/// descriptor to it, so the release no longer waits for a stranger's `exec`. The kernel's own
/// release on the last close still covers a process that dies without running this.
enum AdvisoryLockDescriptor {
    /// Unlock, then close. The unlock's result is deliberately ignored: the `close` that follows
    /// releases the lock in the ordinary case anyway, so a failed `LOCK_UN` degrades to the old
    /// behaviour and never to a leaked descriptor.
    static func unlockAndClose(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
