import Foundation
import Testing
@testable import WhisperCore

// F177 — each action item is linked back to the transcript moment that best supports it, entirely
// locally: the segment sharing the most content words with the item supplies its quote and timestamp,
// which drives the "Play source" control. No model call — derived from the stored segments.

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text)
}

@Test("An action item resolves to the best-matching segment's timestamp and quote (F177)")
func resolvesToBestSegment() {
    let segments = [
        seg(0, "Let's kick off the project."),
        seg(12, "Alice will send the budget spreadsheet to finance by Friday."),
        seg(30, "Any other business? No — thanks everyone."),
    ]
    let resolved = ActionItemEvidence.resolved(["Alice to send the budget spreadsheet"], segments: segments)
    #expect(resolved[0].timestamp == 12)
    #expect(resolved[0].quote?.contains("budget spreadsheet") == true)
}

@Test("An action item with no confident supporting segment keeps a nil timestamp (F177)")
func noMatchStaysNil() {
    let segments = [
        seg(0, "Let's kick off the project."),
        seg(12, "Alice will send the budget spreadsheet to finance by Friday."),
    ]
    let resolved = ActionItemEvidence.resolved(["Schedule the offsite retreat next quarter"], segments: segments)
    #expect(resolved[0].timestamp == nil)
    #expect(resolved[0].quote == nil)
}

@Test("Resolving evidence preserves user-entered done/owner/due (F177)")
func preservesUserFields() {
    let segments = [seg(12, "Alice will send the budget spreadsheet by Friday.")]
    let item = ActionItem(text: "Alice to send the budget spreadsheet", done: true, owner: "Alice", due: "Fri")
    let resolved = ActionItemEvidence.resolved([item], segments: segments)[0]
    #expect(resolved.done)
    #expect(resolved.owner == "Alice")
    #expect(resolved.due == "Fri")
    #expect(resolved.timestamp == 12) // evidence still attached
}

@Test("Segments without a start time cannot supply a timestamp (F177)")
func segmentsWithoutStartYieldNoTimestamp() {
    let segments = [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "Alice will send the budget spreadsheet")]
    let resolved = ActionItemEvidence.resolved(["Alice to send the budget spreadsheet"], segments: segments)
    #expect(resolved[0].timestamp == nil)
}
