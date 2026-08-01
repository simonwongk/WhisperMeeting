import Foundation
import Testing
@testable import WhisperCore

// F84 — the sidebar library filter composes the tested text-query matcher and tag matcher. A selected
// tag must narrow the library (empty selection keeps everything), and the query and tag filters must
// compose with AND. MeetingQuery/MeetingTags themselves are covered elsewhere; this pins the wiring.
private func facets(text: String = "meeting") -> MeetingFacets {
    MeetingFacets(
        languageCode: "en",
        status: "completed",
        durationSeconds: 60,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        textFields: [text]
    )
}

@Test("A selected tag narrows the library; empty selection keeps everything (F84)")
func meetingLibraryFilterTagNarrowing() {
    let base = facets()
    // No tag selected → the meeting is shown regardless of its tags.
    #expect(MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["budget"], selectedTags: [], tagMode: .any))
    #expect(MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: [], selectedTags: [], tagMode: .any))
    // A selected tag shows only meetings that carry it.
    #expect(MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["budget", "q3"], selectedTags: ["budget"], tagMode: .any))
    #expect(!MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["hiring"], selectedTags: ["budget"], tagMode: .any))
    // .all requires every selected tag; .any requires at least one.
    #expect(MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["budget", "q3"], selectedTags: ["budget", "q3"], tagMode: .all))
    #expect(!MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["budget"], selectedTags: ["budget", "q3"], tagMode: .all))
    #expect(MeetingLibraryFilter.includes(query: nil, facets: base, meetingTags: ["budget"], selectedTags: ["budget", "q3"], tagMode: .any))
}

@Test("The text query and the tag selection compose with AND (F84)")
func meetingLibraryFilterComposesQueryAndTags() {
    let passing = MeetingQuery.parse("meeting")       // "meeting" is in textFields → query matches
    let failing = MeetingQuery.parse("zzzznomatch")   // absent from textFields → query fails

    // Query passes AND tag matches → shown.
    #expect(MeetingLibraryFilter.includes(query: passing, facets: facets(), meetingTags: ["budget"], selectedTags: ["budget"], tagMode: .any))
    // Query fails even though the tag matches → hidden.
    #expect(!MeetingLibraryFilter.includes(query: failing, facets: facets(), meetingTags: ["budget"], selectedTags: ["budget"], tagMode: .any))
    // Query passes but the tag does not → hidden.
    #expect(!MeetingLibraryFilter.includes(query: passing, facets: facets(), meetingTags: ["hiring"], selectedTags: ["budget"], tagMode: .any))
}
