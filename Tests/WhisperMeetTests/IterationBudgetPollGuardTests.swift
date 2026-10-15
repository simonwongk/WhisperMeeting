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

@MainActor
@Test("A wait that never holds fails by name as a timeout, not through whatever assertion came next (F957)")
func aTimedOutPollFailsByName() async {
    // The other half of the shape: a budget that ran out used to fall through to an assertion about
    // production. The helper requires its own condition, so the failure names the wait.
    await withKnownIssue("the poll is meant to time out") {
        try await pollUntil("a condition that never holds", timeoutSeconds: 0.05) { false }
    }
}
