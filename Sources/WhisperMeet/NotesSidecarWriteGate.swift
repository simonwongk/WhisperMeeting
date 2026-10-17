import Foundation

/// Whether notes.md may be written right now, readable off the main actor (F751).
///
/// The launch's backfill writes notes.md from a detached pass, and the two states that forbid it —
/// a read-only library (F187) and a restore in progress (F506) — are main-actor state on
/// `MeetingStore`. The pass used to check them once, before it started, so a library that went
/// read-only or a restore that began meanwhile did not stop it. `MeetingStore` mirrors both into
/// this gate whenever either changes, and the pass asks it before each meeting's file.
///
/// The check and the write happen under one lock. So once `setAllowed(false)` returns, no write is in
/// flight and none will start: a write that had already passed the check finishes first, and that
/// wait is one notes.md write. A check-then-write without the lock would leave the window open —
/// narrower, not closed.
final class NotesSidecarWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    func setAllowed(_ value: Bool) {
        lock.withLock { allowed = value }
    }

    var isAllowed: Bool { lock.withLock { allowed } }

    /// Runs `write` only while writes are allowed, holding the gate closed against a change
    /// meanwhile. False, without running it, when they are not.
    func ifAllowed(_ write: () -> Bool) -> Bool {
        lock.withLock { allowed ? write() : false }
    }
}
