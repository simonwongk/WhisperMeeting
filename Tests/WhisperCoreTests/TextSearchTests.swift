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

@Test("A note-only term matches once notes is included in the searched fields")
func notesAreSearchable() {
    // filteredMeetings searches [title, transcript, notes] (F72): a note-only term matches only when
    // notes is part of the fields.
    #expect(TextSearch.matches("attendee", in: ["Weekly Sync", "transcript body", "note: attendee list"]))
    #expect(!TextSearch.matches("attendee", in: ["Weekly Sync", "transcript body"]))
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

@Test("A full-width space (U+3000) between query words splits terms the same as an ASCII space")
func fullWidthSpaceSplitsQueryTerms() {
    // A Chinese IME often inserts U+3000 IDEOGRAPHIC SPACE instead of ASCII space between words.
    let fields = ["Weekly Sync", "We discussed the budget"]
    #expect(TextSearch.matches("weekly\u{3000}budget", in: fields) == TextSearch.matches("weekly budget", in: fields))
    #expect(TextSearch.matches("weekly\u{3000}budget", in: fields))
}

@Test("A full-width Latin query matches half-width text and vice versa")
func widthInsensitiveMatching() {
    #expect(TextSearch.matches("ＡＢＣ", in: ["order code ABC123"]))
    #expect(TextSearch.matches("123", in: ["order code ＡＢＣ１２３"]))
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
