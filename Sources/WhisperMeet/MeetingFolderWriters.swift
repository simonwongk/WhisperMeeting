import Foundation

/// The meetings whose recording folder something is writing into off the main actor, and the ones a
/// delete is removing right now (F870).
///
/// `MeetingStore.delete` removes a folder on the main actor, contents first and the folder last. A
/// file created in between makes the folder's removal fail, and F146's rollback then lists the
/// meeting again after its audio is gone — F849's race. F849 closed it for the meaning index by
/// saving on the main actor. Shrink, Rebuild Audio and the launch notes.md backfill write from
/// detached tasks instead, so each holds the meeting here while it writes, and a delete refuses a
/// held meeting rather than racing it. The refusal is the deferral: the user deletes again once the
/// writer is done, where a race could leave the meeting listed without its audio. A writer that
/// arrives while a delete holds the meeting is turned away and skips it, since its folder is going.
///
/// Locked rather than main-actor-isolated because the backfill's detached pass asks it per meeting.
final class MeetingFolderWriters: @unchecked Sendable {
    private let lock = NSLock()
    private var writing: [UUID: Int] = [:]
    private var deleting: Set<UUID> = []

    /// Starts a write into `id`'s folder; false while a delete of that meeting is under way.
    func begin(_ id: UUID) -> Bool {
        lock.withLock {
            guard !deleting.contains(id) else { return false }
            writing[id, default: 0] += 1
            return true
        }
    }

    /// Ends one `begin` that returned true.
    func end(_ id: UUID) {
        lock.withLock {
            guard let count = writing[id] else { return }
            writing[id] = count > 1 ? count - 1 : nil
        }
    }

    /// Claims `ids` for a delete, except those a writer holds, which are returned as `held` and not
    /// claimed. Every claimed id must be handed back to `endDeletion`.
    func claimForDeletion(_ ids: [UUID]) -> (claimed: [UUID], held: [UUID]) {
        lock.withLock {
            var claimed: [UUID] = [], held: [UUID] = []
            for id in ids {
                if writing[id] != nil {
                    held.append(id)
                } else {
                    deleting.insert(id)
                    claimed.append(id)
                }
            }
            return (claimed, held)
        }
    }

    func endDeletion(_ ids: [UUID]) {
        lock.withLock { deleting.subtract(ids) }
    }
}
