import Testing
@testable import WhisperCore

// F868 — F658 decides Replace by timing, and timing cannot tell a sentence no longer than the
// tolerance plus the engines' boundary disagreement, joined by the other engine to the neighbouring
// line's reading, from jitter. Each fixture here is such a sentence, a quarter- or third-of-a-second
// "Yeah" or "okay" that the other engine put with the neighbouring line: F658's timing offers Replace
// on both lines, and Replace writes the short sentence twice or deletes it. The words at the edges
// say which: the reading ends with the next line's first word, or a segment outside the reading starts
// with this line's last word.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("A short sentence the other engine joined to the end of the line before: neither line offers Replace (F868)")
func aShortSentenceJoinedToThePreviousReadingIsNotOffered() {
    // "Yeah" opens the second line here, and ends the other engine's first segment.
    let primary = [seg("We ship on Friday.", 0, 3.0), seg("Yeah. Next topic.", 3.0, 6.0)]
    let secondary = [seg("We ship Friday, yeah.", 0, 3.3), seg("Next topic.", 3.35, 6.0)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.diverge, .diverge])
    // The first reading carries "yeah", which stays in the second line: Replace would write it twice.
    // The second reading leaves "Yeah" out: Replace would delete it.
    #expect(rows.map(\.offersReplacement) == [false, false])
    #expect(rows.map(\.secondaryText) == ["We ship Friday, yeah.", "Next topic."], "the readings are still shown")
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("A short sentence the other engine joined to the start of the line after: neither line offers Replace (F868)")
func aShortSentenceJoinedToTheNextReadingIsNotOffered() {
    // "okay" closes the first line here, and opens the other engine's second segment.
    let primary = [seg("Next topic, okay.", 0, 3.25), seg("Let's go.", 3.3, 6.0)]
    let secondary = [seg("Next topic.", 0, 2.9), seg("Okay, let's go then.", 2.95, 6.0)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.diverge, .diverge])
    #expect(rows.map(\.offersReplacement) == [false, false])
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("A reading that ends as its line does still offers Replace, though the next line starts with the same word (F868 control)")
func aReadingThatEndsLikeItsLineIsStillOffered() {
    let primary = [seg("I agree, okay.", 0, 3.0), seg("Okay, moving on.", 3.2, 6.0)]
    let secondary = [seg("I agreed, okay.", 0, 3.05), seg("Okay, moving on.", 3.25, 6.0)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.diverge, .agree])
    #expect(rows.first?.offersReplacement == true)
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("The edge match is up to six words, and only where the two edges are the same words (F868)")
func sharedEdgesAreWholeWords() {
    func words(_ text: String) -> [Substring] { TranscriptComparison.words(TranscriptComparison.normalize(text)) }
    #expect(TranscriptComparison.sharedEdge(endOf: words("we ship. Yeah, sure."), startOf: words("Yeah sure, let's go")) == [2])
    #expect(TranscriptComparison.sharedEdge(endOf: words("so so"), startOf: words("so so so")) == [1, 2])
    #expect(TranscriptComparison.sharedEdge(endOf: words("the end"), startOf: words("The beginning")).isEmpty)
    #expect(TranscriptComparison.sharedEdge(endOf: [], startOf: words("a")).isEmpty)
    let seven = words("a b c d e f g")
    #expect(TranscriptComparison.sharedEdge(endOf: seven, startOf: seven).isEmpty, "a match of all seven words is past the limit")
}
