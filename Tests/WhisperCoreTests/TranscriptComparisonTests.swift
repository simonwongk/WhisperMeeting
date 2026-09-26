import Testing
@testable import WhisperCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// F73 — comparing two engines' transcripts.
@Test("Transcript comparison marks agreement, divergence, and non-overlap")
func transcriptComparison() {
    let a = [seg(0, 2, "hello world"), seg(2, 4, "second segment")]

    // Identical inputs → all agree, zero divergences.
    let identical = TranscriptComparison.compare(a, a)
    #expect(identical.allSatisfy { $0.kind == .agree })
    #expect(identical.contains { $0.kind == .diverge } == false)

    // One differing word in an overlapping segment → exactly one divergence carrying both texts.
    let b = [seg(0, 2, "hello world"), seg(2, 4, "second segments")]
    let diff = TranscriptComparison.compare(a, b)
    #expect(diff.filter { $0.kind == .diverge }.count == 1)
    let diverged = diff.first { $0.kind == .diverge }!
    #expect(diverged.primaryText == "second segment")
    #expect(diverged.secondaryText == "second segments")

    // Disjoint timelines → non-overlapping, no crash.
    let disjoint = TranscriptComparison.compare([seg(0, 2, "x")], [seg(10, 12, "y")])
    #expect(disjoint.allSatisfy { $0.kind == .nonOverlapping })
}

// F472 — each line was paired with the FIRST segment of the other transcript that overlapped it at
// all. Two engines' boundaries routinely overlap by a fraction of a second, so the first overlap was
// usually the other engine's PREVIOUS sentence: the row read "Engines differ" and Replace wrote the
// neighbouring sentence over the line — a duplicate, and the real line lost.
@Test("Each line is compared with the segment it overlaps most, not the first one it touches (F472)")
func comparisonPairsEachLineWithItsLargestOverlap() {
    let whisper = [seg(10.0, 13.2, "We should ship on Friday."), seg(13.2, 18.0, "Then we review the numbrs.")]
    let qwen = [seg(9.8, 13.3, "We should ship on Friday."), seg(13.3, 18.1, "Then we review the numbers.")]

    let spans = TranscriptComparison.compare(whisper, qwen)

    #expect(spans.map(\.kind) == [.agree, .diverge])
    #expect(spans[1].secondaryText == "Then we review the numbers.")
}

@Test("An overlapping segment that says the same thing wins over a larger one that does not (F472)")
func comparisonPrefersAnOverlappingSegmentThatAgrees() {
    // The other engine put "Yes." a little late and gave most of this second to the words before
    // it. Largest overlap alone would offer to Replace "Yes." with "so anyway"; both engines did
    // say "Yes." here, so the row agrees and offers nothing to replace.
    let primary = [seg(5.0, 5.5, "Yes.")]
    let other = [seg(4.0, 5.4, "so anyway"), seg(5.4, 5.6, "Yes.")]

    let spans = TranscriptComparison.compare(primary, other)

    #expect(spans.map(\.kind) == [.agree])
    #expect(spans[0].secondaryText == "Yes.")
}

@Test("A line still matches an untimed passage by its text (F472 control)")
func comparisonStillMatchesAnUntimedPassageByText() {
    // The alignment fallback for a Qwen passage the aligner could not time. Unchanged by F472.
    let primary = [seg(0, 2, "hello world"), seg(2, 4, "second segment")]
    let other = [
        TranscriptSegment(speaker: nil, start: nil, end: nil, text: "Hello, world!"),
        seg(2.1, 4.0, "second segments"),
    ]

    let spans = TranscriptComparison.compare(primary, other)

    #expect(spans.map(\.kind) == [.agree, .diverge])
    #expect(spans[1].secondaryText == "second segments")
}

// F570 — `normalize` re-joined its pieces with a space. English has word gaps on both sides, so a
// comma difference vanished; Mandarin has none, so a '，' one engine wrote became a space the other
// engine's text did not have, and the row read "Engines differ" over punctuation alone.
@Test("Punctuation and spacing alone never make two engines differ, in Chinese as in English (F570)")
func comparisonIgnoresPunctuationInEitherScript() {
    let chinese = TranscriptComparison.compare(
        [seg(0, 3, "我们明天开会，然后讨论预算。")], [seg(0, 3, "我们明天开会然后讨论预算")]
    )
    #expect(chinese.map(\.kind) == [.agree])

    // A Latin word in Mandarin, spaced by one engine and not the other.
    let mixed = TranscriptComparison.compare([seg(0, 2, "我们用 Zoom 开会。")], [seg(0, 2, "我们用Zoom开会")])
    #expect(mixed.map(\.kind) == [.agree])

    // The untimed-passage fallback matches by the same normalized text.
    let untimed = TranscriptComparison.compare(
        [seg(0, 3, "我们明天开会，然后讨论预算。")],
        [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "我们明天开会然后讨论预算")]
    )
    #expect(untimed.map(\.kind) == [.agree])

    let english = TranscriptComparison.compare(
        [seg(0, 3, "We meet tomorrow, then discuss.")], [seg(0, 3, "we meet tomorrow then discuss")]
    )
    #expect(english.map(\.kind) == [.agree])
}

@Test("A real difference still reads as one, in Chinese and between English words (F570 control)")
func comparisonStillSeesARealDifference() {
    let chinese = TranscriptComparison.compare([seg(0, 2, "我们明天开会。")], [seg(0, 2, "我们后天开会。")])
    #expect(chinese.map(\.kind) == [.diverge])
    // A space between two Latin words is a word boundary, not punctuation.
    let english = TranscriptComparison.compare([seg(0, 2, "ice cream")], [seg(0, 2, "icecream")])
    #expect(english.map(\.kind) == [.diverge])
}
