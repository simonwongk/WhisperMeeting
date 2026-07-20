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
