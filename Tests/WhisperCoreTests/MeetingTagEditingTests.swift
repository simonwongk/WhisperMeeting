import Testing
@testable import WhisperCore

// F171 — pure input logic for the token-style tag editor: live comma/newline splitting and
// one-click reuse suggestions from the library.

@Test("Live split holds input with no separator as the in-progress remainder")
func liveSplitNoSeparator() {
    let split = MeetingTags.liveSplit("budg")
    #expect(split.ready.isEmpty)
    #expect(split.remainder == "budg")
}

@Test("Live split commits completed parts and keeps the tail in the field")
func liveSplitCommitsCompletedParts() {
    let split = MeetingTags.liveSplit("budget, hiring, q3 pl")
    #expect(split.ready == ["budget", "hiring"])
    #expect(split.remainder == "q3 pl")
}

@Test("Live split treats a trailing separator as a commit with an empty remainder")
func liveSplitTrailingSeparator() {
    let split = MeetingTags.liveSplit("budget,")
    #expect(split.ready == ["budget"])
    #expect(split.remainder == "")
}

@Test("Live split drops empty parts from repeated separators and handles newlines from pastes")
func liveSplitEmptiesAndNewlines() {
    let split = MeetingTags.liveSplit("budget,, \n hiring,")
    #expect(split.ready == ["budget", "hiring"])
    #expect(split.remainder == "")
}

@Test("Reuse suggestions offer unapplied library tags, first-seen spelling, in order, capped")
func reuseSuggestionsBasics() {
    let library = [["Budget", "Hiring"], ["budget", "Q3"], ["Roadmap"]]
    // Applied excludes case-insensitively; duplicates keep the first-seen spelling.
    #expect(MeetingTags.reuseSuggestions(library: library, applied: ["BUDGET"], query: "")
        == ["Hiring", "Q3", "Roadmap"])
    // The query filters by case-insensitive substring.
    #expect(MeetingTags.reuseSuggestions(library: library, applied: [], query: "ro") == ["Roadmap"])
    // The cap bounds the row.
    let many = (1...10).map { ["tag\($0)"] }
    #expect(MeetingTags.reuseSuggestions(library: many, applied: [], query: "", limit: 5).count == 5)
}
