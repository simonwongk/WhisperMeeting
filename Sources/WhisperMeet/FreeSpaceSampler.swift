import Foundation
import os

/// The recording health tick's free-space figure, read away from the capture queue (F877).
///
/// F703 made the read honest: a fresh `URL` per call, so a long recording sees the disk fill. Honest
/// is not cheap. An uncached `volumeAvailableCapacityForImportantUsage` query measured 7.4–24 ms per
/// call spaced a second apart on this Mac, and up to 50 ms in a tight loop (the lane X review and
/// F877's re-run of its probe). The tick ran it every second on `captureQueue`, the queue that also
/// writes every captured buffer and that Stop's `captureQueue.sync` waits on. Not measured, and
/// suspected: the query is slowest near a full disk, exactly when the warning matters.
///
/// So the tick never reads. It asks `latest(for:at:)`, which takes a lock, returns the last figure,
/// and at most every `interval` starts one read on the sampler's own utility queue. The figure the
/// tick sees is therefore up to `interval` plus one read old, which costs little: the warning's
/// margin is ten minutes of the source tracks' growth (`RecordingHealthMonitor`'s
/// `lowStorageReactionWindow`, F530), so ten seconds of staleness is under 2% of it.
///
/// Thread model: `latest` is called on `captureQueue`; the read runs on `queue`; the shared state is
/// behind one lock, so neither side ever waits for the other's work, only for the lock.
final class FreeSpaceSampler: @unchecked Sendable {
    /// How often a fresh read may start. See the type's doc for why ten seconds is cheap.
    static let defaultInterval: TimeInterval = 10

    private struct State {
        /// The directory the figure is for. A new session's directory starts over, because the old
        /// one may be on another volume and its figure is not this one's.
        var directoryPath: String?
        var latest: Int64?
        var lastStartedAt: TimeInterval?
        var readInFlight = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let read: @Sendable (URL) -> Int64?

    init(
        interval: TimeInterval = FreeSpaceSampler.defaultInterval,
        queue: DispatchQueue = DispatchQueue(label: "WhisperMeet.free-space", qos: .utility),
        read: @escaping @Sendable (URL) -> Int64? = { AudioCaptureEngine.availableStorageBytes(at: $0) }
    ) {
        self.interval = interval
        self.queue = queue
        self.read = read
    }

    /// The latest free-space figure for `directory`, without waiting for a read; nil until the first
    /// read for this directory lands, which the health monitor treats as "unknown" (no warning).
    /// Starts a read on the sampler's own queue when none is running and the last one started at
    /// least `interval` before `now` (`now` is `ProcessInfo.systemUptime`, as the tick passes).
    func latest(for directory: URL, at now: TimeInterval) -> Int64? {
        let path = directory.path
        let (figure, startRead): (Int64?, Bool) = state.withLock { state in
            if state.directoryPath != path {
                state = State(directoryPath: path)
            }
            // `now < last` cannot happen with a monotonic clock; if it ever did, read rather than
            // stall until the clock catches up.
            let due = state.lastStartedAt.map { now - $0 >= interval || now < $0 } ?? true
            let start = due && !state.readInFlight
            if start {
                state.readInFlight = true
                state.lastStartedAt = now
            }
            return (state.latest, start)
        }
        if startRead {
            let read = self.read
            let state = self.state
            queue.async {
                let reading = read(directory)
                state.withLock { state in
                    // A read for a directory the tick has moved on from is not this session's figure.
                    guard state.directoryPath == path else { return }
                    state.latest = reading
                    state.readInFlight = false
                }
            }
        }
        return figure
    }
}
