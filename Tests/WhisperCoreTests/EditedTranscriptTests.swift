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
