import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F568 Part 3 — reachable through the composition every notes.md and the manual Export… use
// (`MeetingStore.composeNotes`, the launch backfill's and the debounced flush's only composer).
// The same meeting composed in two zones must name the UTC offset each time, so a sidecar rewritten
// after travel says what changed rather than silently moving the meeting's time. Explicit zones only.

@Test("notes.md names the UTC offset of the time it shows, in every zone (F568)")
func composedNotesNameTheirOffset() throws {
    let created = try #require(ISO8601DateFormatter().date(from: "2026-09-23T23:30:00Z"))
    let meeting = MeetingRecord(
        id: UUID(), title: "Planning sync", createdAt: created, recordingPath: "Recordings/x/meeting.wav",
        status: .completed, transcriptText: "hello world"
    )
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))

    let inNewYork = MeetingStore.composeNotes(for: meeting, timeZone: newYork)
    let inShanghai = MeetingStore.composeNotes(for: meeting, timeZone: shanghai)
    #expect(inNewYork.contains("_2026-09-23 19:30 -04:00"))
    #expect(inShanghai.contains("_2026-09-24 07:30 +08:00"))
    // Composing again in the same zone is byte-identical, which is what lets the launch backfill
    // write nothing for an unchanged meeting.
    #expect(MeetingStore.composeNotes(for: meeting, timeZone: shanghai) == inShanghai)
}
