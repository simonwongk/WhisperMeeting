import Foundation
import Testing
@testable import WhisperCore

// F214 — the refine timeout rate on the real machine, which only the dictation log can settle.
//
// F212 brought every bench case inside its budget on an idle Mac, but the user's runs with ~10 GB of
// swap in use and a resident refiner whose pages were swapped out is not warm. The ticket asks for
// the log bucketed by word count after a week, against F212's baseline (41–60 words: 17 of 18
// `rawTimeout`; 21–40: 11 of 18).
//
// The week of data is the user's to produce. The *analysis* is not, and writing it now is the F244
// precedent: build the harness while its input is still missing, so the answer costs one command
// instead of a session. It also means the bucketing is reviewed before any number depends on it —
// F290 was a scorer whose arithmetic was wrong in the flattering direction, and nobody looks as hard
// at a metric once it has produced a result they like.
//
// **In Swift, deliberately, and beside `DictationRefinePolicy`.** The buckets must use
// `effectiveWordCount` — the app's own counter, which treats majority-CJK text as
// ceil(characters / 2) and is what the 60-word skip threshold actually consults. A Python
// reimplementation would be a second copy of that rule, and F291's lesson is that a port which
// diverges gives a *wrong* verdict rather than none.

private func entry(
    _ text: String, _ refinement: DictationRefinement?, raw: String? = nil
) -> DictationLogEntry {
    DictationLogEntry(
        id: UUID(), date: Date(), text: text, outcome: .pasted,
        rawText: raw, refinement: refinement?.rawValue
    )
}

/// `count` space-separated words, so a test can sit a dictation in a chosen bucket without
/// counting by hand.
private func words(_ count: Int) -> String {
    (0..<count).map { "word\($0)" }.joined(separator: " ")
}

@Test("Entries are bucketed by the word count the policy itself would have used (F214)")
func bucketsUseThePolicysOwnWordCount() {
    let log = DictationLog(entries: [
        entry(words(5), .refined),
        entry(words(30), .rawTimeout),
        entry(words(50), .rawTimeout),
        entry(words(80), .skipped),
    ])
    let report = DictationRefineReport(log: log)

    #expect(report.bucket(.upTo20)?.total == 1)
    #expect(report.bucket(.from21To40)?.total == 1)
    #expect(report.bucket(.from41To60)?.total == 1)
    #expect(report.bucket(.over60)?.total == 1)
}

@Test("The word count comes from the text the policy saw, not the text delivered (F214)")
func theCountUsesTheInputNotTheOutput() {
    // The decision was made on the raw transcript, so that is what the bucket must reflect.
    // `rawText` is recorded only when refinement changed the delivered text, so a refined entry's
    // input is `rawText` and everything else's input is `text` — counting the *delivered* words
    // would shift every refined entry into whichever bucket the cleanup left it in, and filler
    // removal shortens.
    let log = DictationLog(entries: [
        entry(words(18), .refined, raw: words(30))
    ])
    let report = DictationRefineReport(log: log)
    #expect(report.bucket(.from21To40)?.total == 1, "bucketed by the 30 words it decided on")
    #expect(report.bucket(.upTo20) == nil)
}

@Test("A majority-CJK dictation is counted the way the threshold counts it (F214)")
func cjkIsCountedByTheSameRule() {
    // `effectiveWordCount` treats majority-CJK text as ceil(non-whitespace characters / 2), because
    // there are no word spaces. 62 characters is 31 "words" — inside 21–40, and nowhere near the
    // space-delimited count of 1 that a naive split would give.
    let text = String(repeating: "今天", count: 31)
    #expect(DictationRefinePolicy.effectiveWordCount(of: text) == 31)
    let report = DictationRefineReport(log: DictationLog(entries: [entry(text, .rawTimeout)]))
    #expect(report.bucket(.from21To40)?.total == 1)
}

@Test("The timeout rate is over attempts, not over all dictations (F214)")
func theRateExcludesWhatWasNeverAttempted() {
    // `skipped` means the policy declined before the model ran, and `rawBusy` means a previous
    // generation still held the engine. Neither is evidence about decode speed, so counting them in
    // the denominator would dilute exactly the number this ticket exists to measure — and dilute it
    // downward, which is the flattering direction.
    let log = DictationLog(entries: [
        entry(words(30), .rawTimeout),
        entry(words(30), .refined),
        entry(words(30), .skipped),
        entry(words(30), .rawBusy),
    ])
    let bucket = DictationRefineReport(log: log).bucket(.from21To40)
    #expect(bucket?.total == 4)
    #expect(bucket?.attempted == 2, "only the timeout and the refined one were attempts")
    #expect(bucket?.timedOut == 1)
    #expect(bucket?.timeoutRate == 0.5)
}

@Test("A bucket with no attempts has no rate rather than a zero (F214)")
func anUnattemptedBucketHasNoRate() {
    // F290's lesson in its original home: a rate computed from nothing reads as "no timeouts",
    // which is the opposite of "nothing measured".
    let log = DictationLog(entries: [entry(words(30), .skipped)])
    let bucket = DictationRefineReport(log: log).bucket(.from21To40)
    #expect(bucket?.total == 1)
    #expect(bucket?.attempted == 0)
    #expect(bucket?.timeoutRate == nil)
}

@Test("Entries with no refinement recorded are left out entirely (F214)")
func refinementOffIsNotData() {
    // `refinement` is nil when refinement was off or never attempted. Those dictations say nothing
    // about the budget and must not appear in any bucket's total, or the sample size is inflated by
    // however long the feature was disabled.
    let log = DictationLog(entries: [
        entry(words(30), nil),
        entry(words(30), .rawTimeout),
    ])
    let report = DictationRefineReport(log: log)
    #expect(report.bucket(.from21To40)?.total == 1)
    #expect(report.totalConsidered == 1)
}

@Test("An outcome a newer build wrote is counted as unknown, not dropped (F214)")
func anUnknownRefinementIsVisible() {
    // The log stores `refinement` as a raw String precisely so a newer build's value decodes in an
    // older one. Silently skipping it would understate the sample; calling it a timeout would
    // invent data. It is counted, named, and excluded from the rate.
    var entries = [entry(words(30), .rawTimeout)]
    entries.append(DictationLogEntry(
        id: UUID(), date: Date(), text: words(30), outcome: .pasted,
        refinement: "someFutureOutcome"
    ))
    let bucket = DictationRefineReport(log: DictationLog(entries: entries)).bucket(.from21To40)
    #expect(bucket?.total == 2)
    #expect(bucket?.unrecognised == 1)
    #expect(bucket?.attempted == 1, "an outcome we cannot classify is not an attempt we can score")
}

@Test("The report renders the comparison F214 actually asks for (F214)")
func theMarkdownStatesTheBaseline() {
    // The ticket's decision rule is a comparison, not a number: "if timeouts persist mainly on long
    // dictations, consider the 4B refiner; if they are spread evenly, suspect memory pressure".
    // So the rendering carries F212's baseline beside the observed rate, or whoever reads it has to
    // go and find what it is being compared against.
    let log = DictationLog(entries: [
        entry(words(50), .rawTimeout), entry(words(50), .refined),
        entry(words(30), .refined),
    ])
    let markdown = DictationRefineReport(log: log).markdown()
    #expect(markdown.contains("41–60"))
    #expect(markdown.contains("17 of 18"), "F212's baseline for the long bucket")
    #expect(markdown.contains("11 of 18"), "and for the middle one")
    #expect(markdown.contains("memory pressure"), "the reading that a flat distribution implies")
}

@Test("An over-60 dictation that was attempted contradicts the policy and says so (F214)")
func anAttemptedLongDictationIsFlagged() {
    // `decision(for:)` skips above 60 words, so an attempt up there means the log and the policy
    // disagree — a build mismatch, or a threshold changed since. Worth surfacing rather than
    // averaging in: it would be the most interesting line in the report.
    let log = DictationLog(entries: [entry(words(80), .rawTimeout)])
    let report = DictationRefineReport(log: log)
    #expect(report.bucket(.over60)?.attempted == 1)
    #expect(
        report.markdown().contains("above the 60-word skip threshold"),
        "the contradiction has to be named, not smoothed"
    )
}

// MARK: - Running it against the real log

@Test("The report can be produced from a dictation log on disk (F214)")
func theReportRunsAgainstALogFile() throws {
    // `DICTATION_LOG_REPORT=<path to dictation-log.json>` prints the table. Same pattern as F291's
    // `REFINE_GUARD_VERDICTS`: no new executable target, and it reads the file only when someone
    // deliberately asks it to.
    //
    // **I do not run this against the user's library.** AGENTS.md forbids reading their data for
    // testing, and a dictation log is the most personal file in the app — it holds the text of
    // everything they have dictated. The env var exists so *they* can run one command, or so a
    // session can with their explicit go-ahead. Nothing here reaches for a default path.
    //
    // With the variable unset this still exercises the decode-and-render path over a synthetic log
    // written to a temp file, so the file-reading half is covered rather than assumed.
    let path = ProcessInfo.processInfo.environment["DICTATION_LOG_REPORT"]
    // Cleaned up at the END of the test, not at the end of the `else`. The first version put the
    // `defer` inside the branch, so the directory was removed the moment that block exited and the
    // read below failed on a file this test had just written — a scoping mistake that looked exactly
    // like a missing-file bug in the code under test.
    var temporaryDirectory: URL?
    defer { temporaryDirectory.map { try? FileManager.default.removeItem(at: $0) } }

    let url: URL
    if let path {
        url = URL(fileURLWithPath: path)
    } else {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("refine-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        url = directory.appendingPathComponent("dictation-log.json")
        let synthetic = DictationLog(entries: [
            entry(words(50), .rawTimeout),
            entry(words(50), .refined),
            entry(words(30), .refined),
            entry(words(10), .refined),
            entry(words(90), .skipped),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(synthetic).write(to: url)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let log = try decoder.decode(DictationLog.self, from: try Data(contentsOf: url))
    let report = DictationRefineReport(log: log)

    print("""

    === F214: refine outcomes by word count (\(log.entries.count) entries, \
    \(report.totalConsidered) with a refinement outcome) ===
    \(report.markdown())

    """)
    #expect(report.totalConsidered >= 0)
    if path == nil {
        #expect(report.bucket(.from41To60)?.timeoutRate == 0.5, "the synthetic log is 1 of 2")
        #expect(report.bucket(.over60)?.timeoutRate == nil, "a skip is not an attempt")
    }
}
