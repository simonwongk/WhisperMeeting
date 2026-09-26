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

// F569 — a Chinese input method types '，' (U+FF0C) for a comma and commonly joins short lists
// with '、' (U+3001); a full-width '；' (U+FF1B) stands in for ';'. Before the fix these were not
// recognized as separators at all, so '项目，预算' committed as a single tag.
@Test("Live split recognizes the full-width comma a Chinese IME types")
func liveSplitFullWidthComma() {
    let split = MeetingTags.liveSplit("项目，预算，")
    #expect(split.ready == ["项目", "预算"])
    #expect(split.remainder == "")
}

@Test("Live split recognizes the Chinese enumeration comma and full-width semicolon")
func liveSplitEnumerationCommaAndFullWidthSemicolon() {
    let split = MeetingTags.liveSplit("张三、李四；王五、")
    #expect(split.ready == ["张三", "李四", "王五"])
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
