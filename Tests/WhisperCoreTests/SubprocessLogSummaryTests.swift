import Testing
@testable import WhisperCore

@Test("A short log is returned unchanged")
func subprocessLogSummaryPassesShortLogsThrough() {
    let log = "one\ntwo\nthree"
    #expect(SubprocessLogSummary.summarize(log) == "one\ntwo\nthree")
}

@Test("Blank lines are dropped before the character budget is spent")
func subprocessLogSummaryDropsBlankLines() {
    let log = "useful line one\n\n   \n\nuseful line two"
    #expect(SubprocessLogSummary.summarize(log) == "useful line one\nuseful line two")
}

@Test("A long log is capped and keeps the tail, where the useful line lives")
func subprocessLogSummaryCapsLongLogs() {
    let noise = Array(repeating: "progress frame padding", count: 5_000).joined(separator: "\n")
    let log = noise + "\nSkipping meeting.wav due to UnicodeDecodeError"

    let summary = SubprocessLogSummary.summarize(log, maxCharacters: 4_000)

    #expect(summary.count <= 4_000 + "(showing the end of a longer log)\n".count)
    #expect(summary.hasSuffix("Skipping meeting.wav due to UnicodeDecodeError"))
}

@Test("A whitespace-only log still gets an answer instead of an empty string")
func subprocessLogSummaryHandlesWhitespaceOnlyLog() {
    #expect(SubprocessLogSummary.summarize("   \n  \n ") == "")
}
