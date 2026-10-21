import Foundation
import Testing
@testable import WhisperMeet

// F957 — a poll written as `for _ in 0..<N where !done { sleep(10 ms) }` makes "slow" a property of
// the host: N × 10 ms is a budget, and the CI runner is slower than any developer Mac. F956 lost that
// race first (100 × 10 ms against a 1.1 s done pill), and AGENTS.md names both halves of the shape —
// the fixed time budget, and asserting a consequence without requiring the precondition it waited
// for. The tests now poll against a deadline through `pollUntil` and `#require` the wait; this scan
// fails any test that goes back to counting.

@Test("No test polls with an iteration budget; every wait is a deadline poll that is required (F957)")
func noIterationBudgetPolls() throws {
    let pattern = try NSRegularExpression(pattern: #"for _ in 0\.\.<[0-9_]+ where"#)
    var offenders: [String] = []
    var scanned = 0
    for url in try SourceAssertion.swiftFileURLs(under: "Tests") {
        let relative = String(url.path.dropFirst(SourceAssertion.repositoryRoot.path.count + 1))
        // This file quotes the shape in its own comment and in `pattern`; the comment is stripped
        // and the pattern is a regex, not a loop, but a literal match here would be a false report.
        guard url.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent else { continue }
        scanned += 1
        for line in try SourceAssertion.uncommentedLines(relative)
        where pattern.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil {
            offenders.append("\(relative):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
        }
    }
    // Fail closed: a scan that read nothing is a broken scan, not a clean tree.
    #expect(scanned > 100, "scanned only \(scanned) files")
    #expect(offenders.isEmpty, "iteration-budget polls:\n\(offenders.joined(separator: "\n"))")
}

// F1027 — the same budget in another spelling: `while !done, ticks < 6_000 { sleep(5 ms); ticks += 1 }`,
// in thirty-one waits across thirty files, which the `for … where` scan above never saw. A loop bounded
// by a counter against a number literal, whose body sleeps, is a poll with an iteration budget; a
// counted loop that does not sleep (a parser walking characters) is not one, so the body is read too.
@Test("No test polls with a counter bound in a while loop either; every wait is a deadline (F1027)")
func noCounterBoundedWhilePolls() throws {
    let bound = try NSRegularExpression(pattern: #"(^|[,(&|]\s*)[a-z][A-Za-z0-9]*\s*<\s*[0-9][0-9_]*\s*\{"#)
    var offenders: [String] = []
    var scanned = 0
    for url in try SourceAssertion.swiftFileURLs(under: "Tests") {
        let relative = String(url.path.dropFirst(SourceAssertion.repositoryRoot.path.count + 1))
        guard url.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent else { continue }
        scanned += 1
        let lines = try SourceAssertion.uncommentedLines(relative)
        for (position, line) in lines.enumerated()
        where bound.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil {
            // The loop's own line and the next three: a one-line loop or a short body.
            let body = lines[position..<min(lines.count, position + 4)].map(\.text).joined(separator: " ")
            if body.contains("sleep") { offenders.append("\(relative):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))") }
        }
    }
    #expect(scanned > 100, "scanned only \(scanned) files")
    #expect(offenders.isEmpty, "counter-bounded polls:\n\(offenders.joined(separator: "\n"))")
}

// F1066 — a deadline must stand still while the Mac sleeps, as the app's own timers do. A full gate on
// 2026-10-21 failed `aFailedReTapSurvivesTheNoAudioDismiss` after 1.109 s of test time with "the pill was
// never dismissed": the lid was closed mid-run (pmset: "Entering Sleep state due to 'Clamshell Sleep'" at
// 12:45:29), its `ContinuousClock` deadline of 30 s ran out during the sleep, and the 1.2 s dismiss, a
// `DispatchQueue.main.asyncAfter` on uptime, had not fired yet. `ContinuousClock` and `Date()` count sleep;
// `SuspendingClock` does not. Every test deadline is a `SuspendingClock` instant, so no comparison against
// the other two is left in a test.
@Test("No test compares against a clock that runs while the Mac sleeps; deadlines are SuspendingClock (F1066)")
func noDeadlineOnAClockThatCountsSleep() throws {
    let clock = try NSRegularExpression(
        pattern: #"(ContinuousClock(\(\))?\.now|Date\(\))\s*[<>]=?\s*[A-Za-z(]|[A-Za-z0-9_)\]]\s*[<>]=?\s*(ContinuousClock(\(\))?\.now|Date\(\))"#)
    var offenders: [String] = []
    var scanned = 0
    for url in try SourceAssertion.swiftFileURLs(under: "Tests") {
        let relative = String(url.path.dropFirst(SourceAssertion.repositoryRoot.path.count + 1))
        guard url.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent else { continue }
        scanned += 1
        for line in try SourceAssertion.uncommentedLines(relative)
        where clock.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil {
            offenders.append("\(relative):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
        }
    }
    #expect(scanned > 100, "scanned only \(scanned) files")
    #expect(offenders.isEmpty, "deadlines on a clock that counts sleep:\n\(offenders.joined(separator: "\n"))")
}

@MainActor
@Test("A wait that never holds fails by name as a timeout, not through whatever assertion came next (F957)")
func aTimedOutPollFailsByName() async {
    // The other half of the shape: a budget that ran out used to fall through to an assertion about
    // production. The helper requires its own condition, so the failure names the wait.
    await withKnownIssue("the poll is meant to time out") {
        try await pollUntil("a condition that never holds", timeoutSeconds: 0.05) { false }
    }
}
