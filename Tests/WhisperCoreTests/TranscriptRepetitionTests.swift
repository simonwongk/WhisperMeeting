import Foundation
import Testing
@testable import WhisperCore

// F186 — a degenerate decode that loops one line must be detectable across segments.
//
// The existing check is strictly WITHIN a segment: `compressionRatio`, or F55's text-only fallback,
// measures repetition inside one line. A looping decode defeats it completely, because every
// individual line is perfectly clean — the pathology is that the same clean line appears thousands of
// times. Worse than a blind spot: those segments are scored, so the review reports ~100% clean and the
// UI affirmatively vouches for a transcript that is mostly one repeated sentence.

private func seg(_ index: Int, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: Double(index), end: Double(index) + 1, text: text)
}

@Test("A looping transcript is flagged, where the per-segment review calls it clean (F186)")
func flagsCrossSegmentRepetition() {
    // The real shape observed on a 26:24 Qwen transcription: one line repeated thousands of times
    // among a handful of distinct lines, with no segment carrying any model metric.
    var segments = (0..<40).map { seg($0, "第\($0)句不同的話") }
    segments += (0..<600).map { seg(100 + $0, "這是重複的句子") }
    #expect(segments.allSatisfy { $0.compressionRatio == nil })

    // This is the gap, asserted rather than assumed: every individual line is clean, so the existing
    // review scores the transcript and vouches for it at full confidence.
    let report = TranscriptQuality.review(segments)
    #expect(!report.isUnscored)
    #expect(report.flagged.isEmpty)
    #expect(report.confidence == 1.0)

    // ...while 600 of 640 lines are the same sentence.
    let notice = TranscriptQuality.repetitionNotice(segments)
    #expect(notice != nil, "a 600× repeated line was not flagged")
    #expect(notice?.contains("600") == true, "the notice should say how many times it repeated")
}

@Test("A clean transcript of similar length is not flagged (F186)")
func doesNotFlagCleanTranscript() {
    // Mirrors a real sibling recording: every line distinct.
    let segments = (0..<250).map { seg($0, "這是第\($0)句話，內容各不相同。") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}

@Test("Ordinary repeated fillers do not trip the detector (F186)")
func doesNotFlagOrdinaryRepetition() {
    // A real meeting repeats short acknowledgements without being degenerate.
    var segments = (0..<200).map { seg($0, "討論第\($0)個議題的內容。") }
    segments += (0..<12).map { seg(500 + $0, "對。") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}

@Test("A chatty real conversation full of acknowledgements is not accused (F186)")
func doesNotFlagAcknowledgementHeavyConversation() {
    // Taken from a real 131-line meeting that an earlier, looser rule wrongly flagged: "Yeah." 39
    // times and "Bye." 21 times — 48% unique. Nothing is wrong with that transcript.
    var segments = (0..<63).map { seg($0, "Distinct sentence number \($0) with real content.") }
    segments += (0..<39).map { seg(200 + $0, "Yeah.") }
    segments += (0..<21).map { seg(300 + $0, "Bye.") }
    segments += (0..<5).map { seg(400 + $0, "All right.") }
    segments += (0..<3).map { seg(500 + $0, "Okay.") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}

@Test("A stuck decode is caught even though its repeated line is very short (F186)")
func flagsShortLineLoop() {
    // The real loop repeated a TWO-character line ("哎！") — the same length as legitimate fillers, so
    // line length cannot separate them. Dominance can: here one line is 90% of the transcript.
    var segments = (0..<20).map { seg($0, "有內容的一句話第\($0)號") }
    segments += (0..<180).map { seg(300 + $0, "哎！") }
    let notice = TranscriptQuality.repetitionNotice(segments)
    #expect(notice != nil, "a short line repeated for 90% of the transcript was not flagged")
    #expect(notice?.contains("90%") == true)
}

@Test("A short transcript is never flagged, however repetitive (F186)")
func ignoresShortTranscripts() {
    // Too little evidence to call a decode degenerate — and a false accusation on a 6-line transcript
    // is worse than silence.
    let segments = (0..<6).map { seg($0, "好的") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}

@Test("Empty and whitespace-only segments never count as the repeated line (F186)")
func ignoresEmptySegments() {
    var segments = (0..<40).map { seg($0, "第\($0)句不同的話") }
    segments += (0..<600).map { seg(100 + $0, "   ") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}
