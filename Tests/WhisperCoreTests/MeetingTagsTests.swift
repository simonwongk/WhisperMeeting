import Testing
@testable import WhisperCore

/// F67 — tag normalization (trim/dedupe/cap) and AND/OR matching.
@Test("Tag normalization trims, drops empties, dedupes case-insensitively, and caps")
func normalizesTags() {
    #expect(MeetingTags.normalized(["Budget", "budget", "  ", "Hiring", "BUDGET"]) == ["Budget", "Hiring"])

    // Count cap.
    let many = (1...20).map { "tag\($0)" }
    #expect(MeetingTags.normalized(many).count == MeetingTags.maxCount)

    // Length cap.
    let long = String(repeating: "a", count: 50)
    #expect(MeetingTags.normalized([long]).first?.count == MeetingTags.maxLength)
}

@Test("Tag matching honors AND / OR and an empty selection matches all")
func matchesTags() {
    let tags = ["budget", "hiring"]
    #expect(MeetingTags.matches(meetingTags: tags, selected: ["Budget"], mode: .all))
    #expect(!MeetingTags.matches(meetingTags: tags, selected: ["budget", "q3"], mode: .all))
    #expect(MeetingTags.matches(meetingTags: tags, selected: ["budget", "q3"], mode: .any))
    #expect(!MeetingTags.matches(meetingTags: tags, selected: ["q3"], mode: .any))
    #expect(MeetingTags.matches(meetingTags: tags, selected: [], mode: .all)) // no filter → all
}
