import Foundation
import Testing
@testable import WhisperCore

// F740 — a link-imported meeting's captions lined up against its transcript, read-only.

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("Captions are lined up with the transcript line by line: same, different, or not covered (F740)")
func captionsAreComparedLineByLine() throws {
    let transcript = [
        seg(0, 4, "We agreed to ship on Friday."),
        seg(4, 8, "Dana will email Acme about pricing."),
        seg(30, 34, "Thanks, everyone."),
    ]
    // Captions as a video page publishes them: lower case, no punctuation, one word heard differently,
    // and nothing over the last line.
    let captions = [
        seg(0, 4, "we agreed to ship on friday"),
        seg(4, 8, "dana will email acne about pricing"),
    ]
    let rows = CaptionComparison.compare(transcript: transcript, captions: captions)
    #expect(rows.map(\.kind) == [.same, .differs, .notInCaptions])
    #expect(rows.map(\.transcriptText) == transcript.map(\.text))
    try #require(rows.count == 3)
    #expect(rows[1].captionText == "dana will email acne about pricing")
    #expect(rows[2].captionText == nil)
    #expect(rows.map(\.start) == [0, 4, 30])
}

@Test("Mandarin captions are compared without word spaces (F740)")
func mandarinCaptionsCompare() {
    let transcript = [seg(0, 3, "我们周五发布。"), seg(3, 6, "小王负责联系供应商。")]
    let captions = [seg(0, 3, "我们周五发布"), seg(3, 6, "小李负责联系供应商")]
    let rows = CaptionComparison.compare(transcript: transcript, captions: captions)
    #expect(rows.map(\.kind) == [.same, .differs])
}

@Test("With no captions, or no transcript lines, there is nothing to compare (F740)")
func emptySidesGiveNoRows() {
    let lines = [seg(0, 4, "We agreed to ship on Friday.")]
    #expect(CaptionComparison.compare(transcript: lines, captions: []).isEmpty)
    #expect(CaptionComparison.compare(transcript: [], captions: lines).isEmpty)
}
