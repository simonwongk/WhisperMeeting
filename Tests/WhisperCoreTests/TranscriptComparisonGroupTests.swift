import Testing
@testable import WhisperCore

// F869 — when the two engines split the same sentences into lines differently, each line of the group
// is matched with readings it shares with its neighbours, so it read as a difference (without Replace,
// F658) though the engines said the same words. On the real Whisper/Qwen pair (F872) every such group
// was exactly that: "Good morning, everyone." + "Let's get started…" against one segment holding both.
// The user's decision (2026-10-16): "Show matching groups as agreeing" — when a connected group of
// lines and the other engine's segments says the same words in all, its lines count as agreeing and
// leave the differences list. No grouped Replace.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("Two lines the other engine heard as one line, word for word, agree (F869)")
func twoLinesHeardAsOneAgree() {
    // F872's real pair, Qwen as this transcript, Whisper as the second opinion.
    let primary = [seg("Good morning, everyone.", 0.0, 1.2),
                   seg("Let's get started with the weekly planning meeting.", 1.36, 3.84),
                   seg("Sounds good.", 4.0, 4.72)]
    let secondary = [seg("Good morning everyone, let's get started with the weekly planning meeting.", 0.0, 3.76),
                     seg("Sounds good.", 4.08, 4.76)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.agree, .agree, .agree])
    #expect(rows.allSatisfy { !$0.offersReplacement })
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("One line the other engine heard as two, and halves of two lines, agree when the words match (F869)")
func groupsSplitDifferentlyAgree() {
    // One line heard as two segments (already agreement before F869: the joined pieces match).
    let one = TranscriptComparison.compare(
        [seg("Not quite, the installer still needs one more review.", 16.8, 19.84)],
        [seg("Not quite.", 16.8, 17.44), seg("The installer still needs one more review.", 17.68, 19.84)])
    #expect(one.map(\.kind) == [.agree])

    // Halves of two: this transcript's break falls mid-way through the other engine's second segment.
    let primary = [seg("We ship on Friday. The installer", 0, 4.0), seg("still needs a review.", 4.0, 6.0)]
    let secondary = [seg("We ship on Friday.", 0, 2.0), seg("The installer still needs a review.", 2.1, 6.0)]
    let rows = TranscriptComparison.compare(primary, secondary)
    #expect(rows.map(\.kind) == [.agree, .agree])
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("A group whose words differ stays a difference, still without Replace (F869 control)")
func aGroupWhoseWordsDifferStaysADifference() {
    let primary = [seg("Good morning, everyone.", 0.0, 1.2),
                   seg("Let's get started with the weekly planning meeting.", 1.36, 3.84)]
    let secondary = [seg("Good morning everyone, let's get started with the weekly planing meeting.", 0.0, 3.76)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.diverge, .diverge])
    #expect(rows.map(\.offersReplacement) == [false, false], "F658: a shared segment is never offered to one line")
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}

@Test("A group is only lines and segments that share time: a matching neighbour does not pull a differing line in (F869 control)")
func aGroupIsOnlyWhatIsConnected() {
    let primary = [seg("Yeah.", 0, 0.5),
                   seg("Good morning, everyone.", 1.0, 2.2),
                   seg("Let's get started.", 2.3, 3.8),
                   seg("The budget is approved.", 5.0, 7.0)]
    let secondary = [seg("Yeah.", 0, 0.5),
                     seg("Good morning everyone, let's get started.", 1.0, 3.8),
                     seg("The budget was approved.", 5.0, 7.0)]

    let rows = TranscriptComparison.compare(primary, secondary)

    #expect(rows.map(\.kind) == [.agree, .agree, .agree, .diverge])
    #expect(rows.last?.offersReplacement == true, "the lone differing line keeps its Replace")
    #expect(TranscriptComparison.referenceCompare(primary, secondary) == rows)
}
