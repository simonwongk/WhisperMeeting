import Foundation

/// A small, pure state machine for running transcriptions one at a time. The app owns the actual
/// `Task`s; this only tracks which job is active and which are waiting, so the ordering logic is
/// testable without any process or UI. A given id is never active and pending at once, and never
/// pending twice.
public struct TranscriptionQueue: Sendable, Equatable {
    public private(set) var activeID: UUID?
    public private(set) var pending: [UUID]

    public init(activeID: UUID? = nil, pending: [UUID] = []) {
        self.activeID = activeID
        self.pending = pending
    }

    public var isIdle: Bool { activeID == nil }
    public var pendingCount: Int { pending.count }

    /// Whether an id is currently active or waiting.
    public func contains(_ id: UUID) -> Bool { activeID == id || pending.contains(id) }

    /// Whether an id is waiting (not yet started).
    public func isPending(_ id: UUID) -> Bool { pending.contains(id) }

    /// Adds a request to the back of the queue, unless it is already active or pending. Returns
    /// true when it was newly added.
    @discardableResult
    public mutating func enqueue(_ id: UUID) -> Bool {
        guard !contains(id) else { return false }
        pending.append(id)
        return true
    }

    /// If nothing is active and something is waiting, promotes the next id to active and returns it.
    public mutating func startNext() -> UUID? {
        guard activeID == nil, !pending.isEmpty else { return nil }
        return promote()
    }

    /// Marks the active job finished so the next one can start.
    public mutating func finishActive() {
        activeID = nil
    }

    public enum Removal: Sendable, Equatable {
        case notFound
        case wasPending
        case wasActive
    }

    /// Removes an id whether it is active or waiting, reporting which it was.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Removal {
        if activeID == id {
            activeID = nil
            return .wasActive
        }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            return .wasPending
        }
        return .notFound
    }

    private mutating func promote() -> UUID {
        let next = pending.removeFirst()
        activeID = next
        return next
    }
}
