import Foundation
import Testing
@testable import WhisperCore

// F429 — after F420 the splitter still ended a sentence at each `.` of an unspaced ellipsis, so
// "I think...maybe we start" became "I think." / "." / ".maybe we start": a line with no words that
// can never be timed, which `QwenASRClient` then counted as a passage "could not be matched". A run
// of `.`, `?`, `!` is one sentence ending, and a line with no words is not a passage.

private func words(_ text: String, wordSeconds: Double = 0.5) -> [QwenAlignedItem] {
    var items: [QwenAlignedItem] = []
    var time = 0.0
    for piece in text.split(whereSeparator: \.isWhitespace) {
        let word = String(piece.filter { $0.isLetter || $0.isNumber || $0 == "'" })
        guard !word.isEmpty else { continue }
        items.append(QwenAlignedItem(text: word, start: time, end: time + wordSeconds))
        time += wordSeconds
    }
    return items
}

@Test("An unspaced ellipsis stays inside its sentence and leaves no lone \".\" line (F429)")
func anUnspacedEllipsisIsOneSentence() {
    let text = "Good morning everyone. I think...maybe we start with the budget. The venue comes second."
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: words(text))
    #expect(segments.map(\.text) == [
        "Good morning everyone.",
        "I think...maybe we start with the budget.",
        "The venue comes second.",
    ])
    // Words: Good morning everyone (0–1.5) | I thinkmaybe we start with the budget (1.5–5.0) | …
    #expect(segments[1].start == 1.5)
    #expect(segments[1].end == 5.0)
    #expect(segments.allSatisfy { $0.start != nil })
}

@Test("Stacked terminators end one sentence, not several (F429)")
func stackedTerminatorsEndOneSentence() {
    let text = "Really?! Yes. Wait... what?"
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: words(text))
    #expect(segments.map(\.text) == ["Really?!", "Yes.", "Wait...", "what?"])
    #expect(segments.allSatisfy { $0.start != nil })
}

@Test("A line with no words is not counted as a passage that could not be matched (F429)")
func wordlessLinesAreNotUnmatchedPassages() {
    // One genuinely unmatched sentence, plus a line of punctuation the recognizer emitted on its own.
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "One two."),
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "Three four."),
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "…"),
        TranscriptSegment(speaker: nil, start: 2, end: 3, text: "Five six."),
    ]
    let text = segments.map(\.text).joined(separator: " ")
    let payload = QwenOutput(text: text, language: "en", alignedItems: [], alignmentWarning: nil)
    let warning = QwenASRClient.alignmentWarning(text: text, segments: segments, payload: payload)
    #expect(warning?.hasPrefix("1 passage could not be matched") == true)

    // And a transcript whose only untimed line is punctuation has nothing to warn about.
    let clean = [segments[0], segments[2], segments[3]]
    #expect(QwenASRClient.alignmentWarning(text: text, segments: clean, payload: payload) == nil)
}
