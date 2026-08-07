import Testing
@testable import WhisperCore

// F160 — one-pass search index: the occurrence list for counts/navigation plus per-field
// highlight ranges, computed once per query instead of once per redraw.

@Test("Occurrence index matches the occurrences list and per-field ranges of the two-call path")
func occurrenceIndexMatchesTwoCallPath() {
    let fields = ["the budget meeting", "no match here", "budget budget"]
    let query = "budget"
    let index = TextSearch.occurrenceIndex(query, in: fields)
    #expect(index.occurrences == TextSearch.occurrences(query, in: fields))
    #expect(index.rangesByField[0] == TextSearch.occurrenceRanges(query, in: fields[0]))
    #expect(index.rangesByField[2] == TextSearch.occurrenceRanges(query, in: fields[2]))
    #expect(index.rangesByField[1] == nil)
}

@Test("Occurrence index keeps the all-terms-per-field rule for multi-term queries")
func occurrenceIndexMultiTerm() {
    // A field participates only when it contains every term (F43 semantics).
    let fields = ["budget only", "budget review today"]
    let index = TextSearch.occurrenceIndex("budget review", in: fields)
    #expect(index.rangesByField[0] == nil)
    #expect(index.occurrences.map(\.fieldIndex) == [1, 1])
}

@Test("Occurrence index on an empty query is empty")
func occurrenceIndexEmptyQuery() {
    let index = TextSearch.occurrenceIndex("", in: ["anything"])
    #expect(index.occurrences.isEmpty)
    #expect(index.rangesByField.isEmpty)
}
