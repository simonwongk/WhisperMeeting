import Foundation
import Testing
@testable import WhisperCore

// F455 — the transcript as the user left it, as segments for the readers that search or quote it.

private func seg(_ start: Double?, _ text: String, speaker: String? = nil) -> TranscriptSegment {
    TranscriptSegment(speaker: speaker, start: start, end: start.map { $0 + 5 }, text: text, avgLogprob: -0.2)
}

private let original = [
    seg(0, "Kick off the quarterly review.", speaker: "A"),
    seg(12.4, "We'll let Dana go in March.", speaker: "B"),
    seg(30.7, "We'll sue Acme next week.", speaker: "A"),
]

@Test("A transcript with no segments at all is searched as its sentences, untimed (F839)")
func segmentlessTranscriptIsSearchedAsItsSentences() {
    // A Qwen result whose alignment failed keeps its text on one line with no segments.
    let text = "We agreed to move the launch to Friday. Dana will email the vendor about pricing? "
        + "3.5 percent is the cap.\n预算还没批。我们周五再谈"
    let passages = EditedTranscript.searchablePassages(transcriptText: text, segments: [])
    #expect(passages.map(\.text) == [
        "We agreed to move the launch to Friday.", "Dana will email the vendor about pricing?",
        "3.5 percent is the cap.", "预算还没批。", "我们周五再谈",
    ])
    #expect(passages.allSatisfy { $0.start == nil && $0.end == nil && $0.speaker == nil })
    // A clock-like token stays prose (F42): nothing times an untimed transcript.
    #expect(EditedTranscript.searchablePassages(transcriptText: "3:00 PM call with Acme.", segments: [])
        .map(\.text) == ["3:00 PM call with Acme."])
    #expect(EditedTranscript.searchablePassages(transcriptText: " \n ", segments: []).isEmpty)
    // With segments it is exactly the edited-transcript reading, edited or not.
    let unedited = TranscriptFormatter.timestamped(original)
    #expect(EditedTranscript.searchablePassages(transcriptText: unedited, segments: original) == original)
    let edited = "00:00  Kick off the quarterly review.\n00:30  We'll see Acme next week."
    #expect(EditedTranscript.searchablePassages(transcriptText: edited, segments: original)
        == EditedTranscript.effectiveSegments(transcriptText: edited, segments: original))
}

@Test("A segment-less transcript with few sentence marks is cut into passages of a bounded length, at clause marks or spaces (F839)")
func segmentlessPassagesHaveABoundedLength() {
    let limit = EditedTranscript.searchablePassageLimit
    // The review's probe: 2,959 characters and not one sentence mark.
    let unpunctuated = Array(repeating: "we talked about the launch and the vendor and the pricing for a long time", count: 40)
        .joined(separator: " ")
    let english = EditedTranscript.searchablePassages(transcriptText: unpunctuated, segments: [])
    #expect(english.count > 1)
    #expect(english.allSatisfy { $0.text.count <= limit && $0.start == nil })
    // Cut between words, and no word is lost.
    #expect(english.map(\.text).joined(separator: " ") == unpunctuated)
    // The review's other probe: Chinese with only commas, cut just after one.
    let commas = Array(repeating: "我们讨论了发布时间，供应商的价格，还有预算", count: 30).joined(separator: "，")
    let chinese = EditedTranscript.searchablePassages(transcriptText: commas, segments: [])
    #expect(chinese.count > 1)
    #expect(chinese.allSatisfy { $0.text.count <= limit })
    #expect(chinese.dropLast().allSatisfy { $0.text.hasSuffix("，") })
    #expect(chinese.map(\.text).joined() == commas)
    // With no mark and no space at all, it is cut at the limit.
    let unbroken = String(repeating: "我们讨论了发布时间供应商的价格还有预算", count: 30)
    let cut = EditedTranscript.searchablePassages(transcriptText: unbroken, segments: [])
    #expect(cut.count > 1)
    #expect(cut.allSatisfy { $0.text.count <= limit })
    #expect(cut.map(\.text).joined() == unbroken)
    // A sentence within the limit is one passage, as before.
    #expect(EditedTranscript.searchablePassages(transcriptText: "Short, and sweet. Done", segments: [])
        .map(\.text) == ["Short, and sweet.", "Done"])
}

@Test("An unedited transcript reads exactly its stored segments, metrics and all (F455)")
func uneditedTranscriptIsItsSegments() {
    let text = TranscriptFormatter.timestamped(original)
    #expect(EditedTranscript.effectiveSegments(transcriptText: text, segments: original) == original)
}

@Test("A cleared transcript reads as no lines at all, not as the lines it was cleared of (F837)")
func clearedTranscriptHasNoSegments() {
    #expect(EditedTranscript.effectiveSegments(transcriptText: "", segments: original).isEmpty)
    #expect(EditedTranscript.effectiveSegments(transcriptText: " \n\n ", segments: original).isEmpty)
    // Never transcribed: no lines either way.
    #expect(EditedTranscript.effectiveSegments(transcriptText: "", segments: []).isEmpty)
}

@Test("A correction inside lines that still align keeps each segment's precise timing and speaker (F455)")
func alignedCorrectionKeepsTimings() {
    let text = TranscriptFormatter.timestamped(original).replacingOccurrences(of: "sue", with: "see")
    let effective = EditedTranscript.effectiveSegments(transcriptText: text, segments: original)
    #expect(effective.map(\.text) == ["Kick off the quarterly review.", "We'll let Dana go in March.", "We'll see Acme next week."])
    // Annotated, not inferred: CI's Swift 6.1 types a bare array literal on its own (AGENTS.md).
    let starts: [Double?] = [0, 12.4, 30.7]
    let speakers: [String?] = ["A", "B", "A"]
    #expect(effective.map(\.start) == starts)
    #expect(effective.map(\.end) == original.map(\.end))
    #expect(effective.map(\.speaker) == speakers)
}

@Test("A deleted line is gone, and the remaining lines take the time they show (F455)")
func deletedLineIsGone() {
    let text = "00:00  Kick off the quarterly review.\n\n00:30  We'll see Acme next week.\nA line I typed myself."
    let effective = EditedTranscript.effectiveSegments(transcriptText: text, segments: original)
    #expect(effective.map(\.text) == ["Kick off the quarterly review.", "We'll see Acme next week.", "A line I typed myself."])
    let starts: [Double?] = [0, 30, nil]
    #expect(effective.map(\.start) == starts)
    #expect(effective.allSatisfy { $0.end == nil && $0.speaker == nil })
    #expect(!effective.contains { $0.text.contains("Dana") })
}

@Test("Without timed segments a leading clock is prose, so nothing is parsed off the line (F455, F42)")
func untimedTranscriptKeepsClockLikeProse() {
    let untimed = [seg(nil, "Standup moved."), seg(nil, "Nothing else.")]
    let text = "Standup moved.\n3:00 PM call with Acme instead."
    let effective = EditedTranscript.effectiveSegments(transcriptText: text, segments: untimed)
    #expect(effective.map(\.text) == ["Standup moved.", "3:00 PM call with Acme instead."])
    let starts: [Double?] = [nil, nil]
    #expect(effective.map(\.start) == starts)
}
