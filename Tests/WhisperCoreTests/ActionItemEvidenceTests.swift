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

@Test("An untimed passage still supplies a quote, with no timestamp (F919)")
func untimedPassageSuppliesAQuoteWithoutATimestamp() {
    // What `EditedTranscript.searchablePassages` gives a meeting with text and no segments (F839).
    let segments = [
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "We agreed to move the launch to Friday."),
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "Dana will email the vendor about pricing."),
    ]
    let resolved = ActionItemEvidence.resolved(["Dana to email the vendor about pricing"], segments: segments)
    #expect(resolved[0].quote == "Dana will email the vendor about pricing.")
    #expect(resolved[0].timestamp == nil, "untimed: nothing to play from")
}

@Test("A timed segment and an untimed one with the same overlap: the earlier wins, timed or not (F919)")
func untimedAndTimedCandidatesTieByOrder() {
    let segments = [
        seg(3, "Dana will email the vendor."),
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "Dana will email the vendor again."),
    ]
    let resolved = ActionItemEvidence.resolved(["Dana to email the vendor"], segments: segments)
    #expect(resolved[0].quote == "Dana will email the vendor.")
    #expect(resolved[0].timestamp == 3)
}

// F177 — Mandarin is a first-class supported language, and Chinese has no word spacing, so evidence
// matching must work on character bigrams rather than whole space-delimited words.
@Test("A Chinese (space-free) action item resolves to its supporting segment (F177)")
func resolvesChineseActionItem() {
    let segments = [
        seg(0, "大家好，我们现在开始。"),
        seg(12, "我们需要发送预算表给财务部门。"),
        seg(30, "没有其他事情了，谢谢大家。"),
    ]
    let resolved = ActionItemEvidence.resolved(["发送预算表给财务"], segments: segments)
    #expect(resolved[0].timestamp == 12)
    #expect(resolved[0].quote?.contains("发送预算表") == true)
}
