import Foundation

/// Counts the writes a piece of work has completed, for someone who has to tell slow work from
/// stuck work without touching the disk themselves (F929).
///
/// The quit waits for a stop that is saving a recording, and that save can legitimately take a
/// long time: the mix of a one-hour recording measured 53 s in a debug build on a developer Mac.
/// A bound on the whole wait would cut such a save short. What a volume that has stopped answering
/// does differently is stop completing writes, so the wait is bounded on that instead.
///
/// Scoped with a task-local rather than counted process-wide: `ThrowingFileHandleIO.write` is also
/// how dictation talks to its helper, and only the writes of the task that bound `current` (and
/// the child tasks it starts) are this work's progress.
public final class WriteProgress: @unchecked Sendable {
    /// The counter the current task's writes report to, or nil when nobody is counting.
    @TaskLocal public static var current: WriteProgress?

    private let lock = NSLock()
    private var count: UInt64 = 0

    public init() {}

    /// How many writes have completed so far. Only its changes mean anything.
    public var ticks: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// One more write completed. Wraps rather than traps: a count that has gone round still changed.
    public func tick() {
        lock.lock(); defer { lock.unlock() }
        count &+= 1
    }
}

/// Whether work that should be making progress has gone quiet for longer than `bound` (F929).
///
/// Every change in the tick count restarts the quiet period, so work that keeps completing writes
/// is never called stalled however long it runs. A value type the caller keeps between polls.
public struct ProgressStallWatch: Sendable {
    public let bound: Duration
    private var lastTicks: UInt64
    private var quietSince: ContinuousClock.Instant

    public init(bound: Duration, ticks: UInt64, now: ContinuousClock.Instant) {
        self.bound = bound
        self.lastTicks = ticks
        self.quietSince = now
    }

    /// Records what the counter reads at `now`, and says whether it has now been unchanged for at
    /// least `bound`.
    public mutating func hasStalled(ticks: UInt64, now: ContinuousClock.Instant) -> Bool {
        if ticks != lastTicks {
            lastTicks = ticks
            quietSince = now
        }
        return now - quietSince >= bound
    }
}
