import Foundation
import Testing
@testable import WhisperCore

/// F76 — calendar title matching for a new recording.
@Test("Calendar matcher picks a containing event, then the nearest within tolerance")
func calendarTitleMatcher() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func ev(_ title: String, _ startOffset: TimeInterval, _ endOffset: TimeInterval) -> CalendarEventSummary {
        CalendarEventSummary(
            title: title,
            start: base.addingTimeInterval(startOffset),
            end: base.addingTimeInterval(endOffset)
        )
    }
    let tolerance: TimeInterval = 300 // 5 minutes

    // A start inside an event returns its title.
    #expect(CalendarTitleMatcher.bestTitle(
        forRecordingStartedAt: base.addingTimeInterval(60), in: [ev("Standup", 0, 900)], tolerance: tolerance
    ) == "Standup")

    // A start 2 minutes before an event start (within tolerance) returns it.
    #expect(CalendarTitleMatcher.bestTitle(
        forRecordingStartedAt: base, in: [ev("Sync", 120, 1000)], tolerance: tolerance
    ) == "Sync")

    // No nearby event returns nil.
    #expect(CalendarTitleMatcher.bestTitle(
        forRecordingStartedAt: base, in: [ev("Far", 3600, 4000)], tolerance: tolerance
    ) == nil)

    // Two overlapping events containing the start resolve to the earliest-start title.
    #expect(CalendarTitleMatcher.bestTitle(
        forRecordingStartedAt: base.addingTimeInterval(60),
        in: [ev("Later", 30, 900), ev("Earlier", 0, 900)],
        tolerance: tolerance
    ) == "Earlier")
}
