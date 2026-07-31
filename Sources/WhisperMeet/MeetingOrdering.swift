import Foundation

/// Pure ordering for the meeting sidebar: pinned meetings first, then newest `createdAt` first.
/// Extracted so the ordering is unit-testable and applied identically everywhere the store sorts,
/// letting a reference or recurring recording stay reachable at the top (F64).
enum MeetingOrdering {
    static func sorted(_ meetings: [MeetingRecord]) -> [MeetingRecord] {
        meetings.sorted { lhs, rhs in
            let lhsPinned = lhs.pinned ?? false
            let rhsPinned = rhs.pinned ?? false
            if lhsPinned != rhsPinned { return lhsPinned } // pinned first
            return lhs.createdAt > rhs.createdAt           // then newest first
        }
    }
}
