import Testing
@testable import WhisperCore

@Test("An empty query matches everything")
func emptyQueryMatches() {
    #expect(TextSearch.matches("", in: ["anything"]))
    #expect(TextSearch.matches("   ", in: ["anything"]))
}

@Test("Matching is case- and diacritic-insensitive across fields")
func matchesAcrossFields() {
    #expect(TextSearch.matches("SYNC", in: ["Weekly Sync", "transcript body"]))
    #expect(TextSearch.matches("cafe", in: ["Café meeting notes"]))
    #expect(TextSearch.matches("budget", in: ["Q3 plan", "We discussed the budget"]))
}

@Test("Every term must appear in some field")
func requiresAllTerms() {
    #expect(TextSearch.matches("weekly sync", in: ["Weekly Sync"]))
    #expect(!TextSearch.matches("weekly retro", in: ["Weekly Sync"]))
}

@Test("A query with no matching term fails")
func noMatch() {
    #expect(!TextSearch.matches("invoice", in: ["Weekly Sync", "standup notes"]))
}

@Test("Search returns every case- and diacritic-insensitive occurrence for highlighting")
func findsHighlightRanges() {
    let text = "Café owners discussed CAFE pricing at another cafe."

    let ranges = TextSearch.occurrenceRanges("cafe", in: text)

    #expect(ranges.map { String(text[$0]) } == ["Café", "CAFE", "cafe"])
}

@Test("Overlapping query terms count and highlight one merged region, not two")
func mergesOverlappingRanges() {
    // "meet" is a substring of the only match of "meeting" — one visible region, one match.
    let overlapping = TextSearch.occurrenceRanges("meet meeting", in: "the meeting is set")
    #expect(overlapping.count == 1)
    #expect(overlapping.map { String("the meeting is set"[$0]) } == ["meeting"])

    // A duplicated query word must not double-count its single occurrence.
    #expect(TextSearch.occurrences("the the", in: ["the cat"]).count == 1)

    // Adjacent but non-overlapping matches stay distinct.
    #expect(TextSearch.occurrenceRanges("a b", in: "ab").count == 2)
}

@Test("Search indexes every occurrence across matching transcript lines")
func indexesEveryOccurrence() {
    let occurrences = TextSearch.occurrences(
        "budget",
        in: ["Budget, budget, BUDGET", "No match", "Final budget"]
    )

    #expect(occurrences == [
        TextSearchOccurrence(fieldIndex: 0, occurrenceIndex: 0),
        TextSearchOccurrence(fieldIndex: 0, occurrenceIndex: 1),
        TextSearchOccurrence(fieldIndex: 0, occurrenceIndex: 2),
        TextSearchOccurrence(fieldIndex: 2, occurrenceIndex: 0),
    ])
}
