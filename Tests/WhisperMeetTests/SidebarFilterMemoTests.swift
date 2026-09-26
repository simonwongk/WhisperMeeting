import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F519 — a sidebar search re-ran the case-/diacritic-insensitive scan over EVERY meeting's title,
// transcript and notes at least three times per redraw: once for the empty-state check, once for the
// ForEach, and again through `selectedMeetingIDs` — per visible row, through the context menu (~1.3s
// per redraw at 100 meetings, ~13s at 1,000, measured). `ContentView.filteredMeetings` now answers
// through a `LastValueMemo` (F541's own pattern): any number of reads with the same meetings/query/tags
// cost one scan, and only a genuinely different input pays for another.
//
// Counted through a seam, never timed: how often the scan runs is a property of the code; how long it
// takes is a property of the host (AGENTS.md: "Never assert on host-dependent state in a test").

private func syntheticMeeting(_ index: Int, matches term: Bool) -> MeetingRecord {
    // Filler long enough that an unmemoized case-/diacritic-insensitive scan does real work
    // proportional to an actual transcript, not a one-line stub.
    let filler = String(repeating: "The quarterly roadmap review covered budget and headcount. ", count: 40)
    return MeetingRecord(
        id: UUID(),
        title: "Standup \(index)",
        duration: 1_800,
        status: .completed,
        transcriptText: term ? filler + "Dana asked about the kestrel migration." : filler,
        languageCode: "en"
    )
}

/// A synthetic 2,000-meeting library — never a user's data (AGENTS.md), built in memory so the test
/// stays fast and needs no fixture files.
private let syntheticLibrary: [MeetingRecord] = (0..<2_000).map { syntheticMeeting($0, matches: $0 == 1_500) }

/// Mirrors `ContentView.filteredMeetings`'s own compute closure exactly — parse the query, then
/// `MeetingLibraryFilter.includes` per meeting — so the count this test asserts on is the count that
/// closure actually does, not a simplified stand-in.
private func scanOnce(
    _ meetings: [MeetingRecord],
    searchText: String,
    selectedTags: Set<String>,
    scans: inout Int
) -> [MeetingRecord] {
    scans += 1
    let raw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = raw.isEmpty ? nil : MeetingQuery.parse(raw)
    let selected = Array(selectedTags)
    guard query != nil || !selected.isEmpty else { return meetings }
    return meetings.filter { meeting in
        MeetingLibraryFilter.includes(
            query: query,
            facets: MeetingFacets(
                languageCode: meeting.languageCode,
                status: meeting.status.rawValue,
                durationSeconds: meeting.duration,
                createdAt: meeting.createdAt,
                textFields: [meeting.title, meeting.transcriptText, meeting.notes ?? ""]
            ),
            meetingTags: meeting.tags ?? [],
            selectedTags: selected,
            tagMode: .any
        )
    }
}

@Test("A redraw's repeated reads of the filtered list scan the 2,000-meeting library once, not once per read (F519)")
func filteredListScansOncePerRedrawNotOncePerRead() {
    let memo = LastValueMemo<SidebarFilterInput, [MeetingRecord]>()
    var scans = 0
    func filtered(searchText: String, selectedTags: Set<String>, meetings: [MeetingRecord] = syntheticLibrary) -> [MeetingRecord] {
        memo.value(for: SidebarFilterInput(meetings: meetings, searchText: searchText, selectedTags: selectedTags)) { input in
            scanOnce(input.meetings, searchText: input.searchText, selectedTags: input.selectedTags, scans: &scans)
        }
    }

    // One redraw's worth of reads, at the rate ContentView's body made them before F519: the
    // empty-state check, the ForEach, and `selectedMeetingIDs` once per visible row's context menu.
    // One match ("Dana") in 2,000 meetings, so an unmemoized scan does 2,000 real comparisons every time.
    func redraw() -> [MeetingRecord] {
        _ = filtered(searchText: "Dana", selectedTags: []).isEmpty      // the empty-state check
        let forEachResult = filtered(searchText: "Dana", selectedTags: []) // the ForEach
        for _ in 0..<3 {                                                  // 3 visible rows' context menus
            _ = filtered(searchText: "Dana", selectedTags: []).contains { $0.title == "Standup 1500" }
        }
        return forEachResult
    }

    let result = redraw()
    #expect(result.count == 1)
    #expect(result.first?.title == "Standup 1500")
    #expect(scans == 1, "one redraw's 5 reads of the same input must scan once, not 5 times")

    // A second redraw with the identical query/tags/library costs nothing extra.
    _ = redraw()
    #expect(scans == 1)

    // A genuinely different query is a genuinely different answer, and costs one more scan.
    _ = filtered(searchText: "kestrel", selectedTags: [])
    #expect(scans == 2)

    // A changed library (a note saved, a transcription completing) is a different input too — the
    // memo must not paper over a real change.
    var changedLibrary = syntheticLibrary
    changedLibrary[0].notes = "follow up"
    _ = filtered(searchText: "kestrel", selectedTags: [], meetings: changedLibrary)
    #expect(scans == 3)
}

// ContentView has no render harness (F174), so the wiring is pinned on its source, comments stripped
// first (F285's sharp edge: a paragraph explaining a regression must not satisfy the check meant to
// detect it).
@Test("ContentView's filteredMeetings reaches the scan only through the memo (F519)")
func filteredMeetingsReachesTheScanOnlyThroughTheMemo() throws {
    let contentView = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(contentView.contains("filterMemo.value(for: SidebarFilterInput("), """
        ContentView.filteredMeetings must route through filterMemo (a LastValueMemo, F541's pattern), \
        or every read site — the empty-state check, the ForEach, selectedMeetingIDs, and each visible \
        row's context menu — reruns the full text/tag scan again.
        """)
}
