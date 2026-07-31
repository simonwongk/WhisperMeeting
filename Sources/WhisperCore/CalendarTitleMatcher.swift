import Foundation

/// A framework-free calendar event (no EventKit dependency in WhisperCore). The app builds these
/// from EventKit; the matching logic stays pure and testable (F76).
public struct CalendarEventSummary: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date

    public init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }
}

public enum CalendarTitleMatcher {
    /// The best event title to pre-fill for a recording that began at `recordingStart`:
    /// 1. an event whose `[start, end]` contains the recording start (overlaps resolved by earliest
    ///    start, then title, for determinism), else
    /// 2. the event whose start is closest to the recording start and within `tolerance`.
    /// `nil` when nothing qualifies (the caller keeps its auto-title).
    public static func bestTitle(
        forRecordingStartedAt recordingStart: Date,
        in events: [CalendarEventSummary],
        tolerance: TimeInterval
    ) -> String? {
        let containing = events
            .filter { $0.start <= recordingStart && recordingStart <= $0.end }
            .sorted { deterministicallyBefore($0, $1) }
        if let match = containing.first { return match.title }

        let nearby = events
            .filter { abs($0.start.timeIntervalSince(recordingStart)) <= tolerance }
            .sorted { lhs, rhs in
                let dl = abs(lhs.start.timeIntervalSince(recordingStart))
                let dr = abs(rhs.start.timeIntervalSince(recordingStart))
                if dl != dr { return dl < dr }
                return deterministicallyBefore(lhs, rhs)
            }
        return nearby.first?.title
    }

    private static func deterministicallyBefore(_ lhs: CalendarEventSummary, _ rhs: CalendarEventSummary) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start } // earliest start wins
        return lhs.title < rhs.title
    }
}
