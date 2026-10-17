import Foundation
import Testing
@testable import WhisperMeet

// F907 — the week-later shred rewrites every retained index generation on the main actor. It ran at
// launch before orphan recovery and the startup notice, so on a large library the recording a crash
// interrupted and the notice saying it came back both waited behind it (18.7 s at 1,000 meetings,
// before F907 made the shred itself faster). It now runs after them. Asserted on the source,
// comments stripped, because the order lives in one long launch method whose shred has no seam a test
// could time.

@Test("The launch shred runs after orphan recovery and the startup notice (F907)")
func launchShredRunsAfterLaunchCriticalWork() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let start = try #require(source.range(of: "func performStartupRecovery() async {"))
    let end = try #require(source.range(of: "func installLocalWhisper() {", range: start.upperBound..<source.endIndex))
    let body = String(source[start.upperBound..<end.lowerBound])

    let shreds = body.ranges(of: "store.processPendingShreds()")
    try #require(shreds.count == 1, "expected one launch shred, found \(shreds.count)")
    let shred = shreds[0].lowerBound
    let orphans = try #require(body.range(of: "try store.orphanedRecordings()"))
    #expect(orphans.lowerBound < shred, "the shred runs before orphan recovery")
    let summaries = body.ranges(of: "report(summary)")
    let lastSummary = try #require(summaries.last)
    #expect(lastSummary.lowerBound < shred, "the shred runs before the startup notice is reported")
}
