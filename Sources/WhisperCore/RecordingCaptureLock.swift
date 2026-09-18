import Foundation

/// A per-folder claim that "this recording is being written right now", answered by the kernel
/// (F297).
///
/// **The problem it settles.** A running capture's folder is structurally identical to an
/// interrupted one — raw `.f32` tracks and no `meeting.wav`, which only `AudioCaptureEngine.stop()`
/// writes. F255 therefore refused to rebuild *anything* while another instance held the library
/// lease, which answers "is another copy open", not "is this folder live". So a recording that
/// crashed in one instance stayed unrecovered for as long as any other copy of the app was open,
/// and F257 established that a copy is open more or less always.
///
/// **The mechanism is the library lease's (F190), moved to the folder.** The capturing process takes
/// an exclusive advisory `flock` on `capture.lock` inside its recording folder and holds the
/// descriptor for the life of the capture. The kernel releases the lock on the last close of that
/// descriptor — including after `SIGKILL` and a crash — so:
///
/// - lock **held** ⇒ the writer is alive, and the folder must not be rebuilt, whatever the lease
///   says;
/// - lock file present and **free** ⇒ the writer is gone, and the folder may be rebuilt even while
///   another instance holds the lease;
/// - **no lock file** ⇒ the folder was written by a build before this one, or by something else, and
///   nothing is known: the caller falls back to the F255 lease rule.
///
/// The third case is what keeps this an *addition* to F255's gate rather than a replacement. F279
/// kept the lease as an additional refusal so that a probe failure degrades to a deferred recovery
/// rather than a re-run of F255; the lock keeps that promise by only ever adding a refusal (a live
/// writer) or vouching for a folder it has positive evidence about.
///
/// Advisory only, and never a reason to refuse a *capture*: `acquire` failing leaves recording
/// exactly as it was before this type existed.
public enum RecordingCaptureLock {
    public static let filename = "capture.lock"

    /// An open, flocked descriptor. The lock lives in the open file description, so the handle
    /// must outlive the capture; closing it releases the lock, which is the point.
    public final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?
        private let url: URL

        /// Internal, for the close-on-exec assertion. Never public API.
        var descriptorForTesting: Int32? { lock.withLock { descriptor } }

        fileprivate init(descriptor: Int32, url: URL) {
            self.descriptor = descriptor
            self.url = url
        }

        /// Idempotent, and called from `deinit`.
        ///
        /// - Parameter removingFile: unlink the lock file as well — a clean finish, so the folder
        ///   is not left looking like a crash to the next probe, and so `removeIfEmpty` after a
        ///   failed start is not defeated by a 0-byte leftover. Removed AFTER the close: a probe
        ///   that opened the file in between still sees the held lock until then.
        public func release(removingFile: Bool = false) {
            let toClose: Int32? = lock.withLock {
                defer { descriptor = nil }
                return descriptor
            }
            guard let toClose else { return }
            close(toClose)
            if removingFile { try? FileManager.default.removeItem(at: url) }
        }

        deinit { release() }
    }

    /// What a probe found. `released` carries the lock the probe now HOLDS: the sweep keeps it for
    /// the rebuild, so a third instance probing meanwhile sees a live holder rather than joining in.
    public enum Probe: Equatable {
        case noLockFile
        case heldByLiveWriter
        case released(Handle)
        case unavailable(reason: String)

        public static func == (lhs: Probe, rhs: Probe) -> Bool {
            switch (lhs, rhs) {
            case (.noLockFile, .noLockFile), (.heldByLiveWriter, .heldByLiveWriter): return true
            case (.released(let a), .released(let b)): return a === b
            case (.unavailable(let a), .unavailable(let b)): return a == b
            default: return false
            }
        }
    }

    /// The writer's side: take the folder's lock for the life of a capture, or nil.
    ///
    /// Nil covers a held lock (another live writer — a state `startRecording` cannot reach today,
    /// since a folder is named by a fresh UUID) and a volume where the lock cannot be taken at all.
    /// Both are tolerated: recording proceeds exactly as it did before F297.
    ///
    /// `O_CLOEXEC` is mandatory, for the library lease's reason: the app spawns whisper and Qwen
    /// helper subprocesses, and a child that inherited the descriptor would hold the folder "live"
    /// after the parent died — and since it would be held by a live process, nothing could ever
    /// call it stale.
    public static func acquire(in directory: URL) -> Handle? {
        let url = directory.appendingPathComponent(filename)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return Handle(descriptor: descriptor, url: url)
    }

    /// The reader's side: is this folder's writer alive? Never creates the file — a probe that
    /// created it would turn every old-build folder into a "released" one on its second look.
    public static func probe(in directory: URL) -> Probe {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return .noLockFile }
        // Read-only is enough: `flock(LOCK_EX)` on a read-only descriptor is legal, and it means
        // a foreign-owned-but-readable lock file can still be probed.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .unavailable(reason: "could not open the lock (errno \(errno))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            return failure == EWOULDBLOCK
                ? .heldByLiveWriter
                : .unavailable(reason: "flock failed (errno \(failure))")
        }
        return .released(Handle(descriptor: descriptor, url: url))
    }
}
