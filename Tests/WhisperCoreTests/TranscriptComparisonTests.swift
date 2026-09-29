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

// F572 — F472 paired each line with the ONE segment of the other transcript it overlapped most. When
// the two engines split sentences differently that is still one-to-one: this transcript's "A. B." over
// the other engine's "A." and "B." offered only "B.", and Replace wrote "B." over "A. B." — a sentence
// both engines heard, deleted. Every segment that overlaps the line by a real share of the shorter
// span is joined, in time order; a sliver of the shorter span is no counterpart at all. (A SHORT
// neighbour's sliver of the line can be a quarter of its own span — the cases F658 is for.)
@Test("A line the other engine split in two is offered the whole of its reading, not the larger piece (F572)")
func comparisonJoinsEverySegmentTheLineCovers() {
    // The ticket's exhibit: the same words, split differently — the engines agree.
    let same = TranscriptComparison.compare(
        [seg(10, 18, "We ship on Friday. Then we review the numbers.")],
        [seg(10, 13, "We ship on Friday."), seg(13, 18, "Then we review the numbers.")]
    )
    #expect(same.map(\.kind) == [.agree])

    // A real difference in the second half: the row offers BOTH halves, so Replace keeps the first.
    let different = TranscriptComparison.compare(
        [seg(10, 18, "We ship on Friday. Then we review the numbrs.")],
        [seg(10, 13, "We ship on Friday."), seg(13, 18, "Then we review the numbers.")]
    )
    #expect(different.map(\.kind) == [.diverge])
    #expect(different.first?.secondaryText == "We ship on Friday. Then we review the numbers.")
}

@Test("The other engine's pieces are joined in time order, and without a space between Chinese sentences (F572)")
func comparisonJoinsInTimeOrderAndRespectsChineseSpacing() {
    // Out of order in the list — the join follows the clock, not the array.
    let english = TranscriptComparison.compare(
        [seg(0, 6, "One two three four.")],
        [seg(3, 6, "Three for."), seg(0, 3, "One two.")]
    )
    #expect(english.first?.secondaryText == "One two. Three for.")

    // Mandarin has no word spaces: a space between the two pieces would be written into the line.
    let chinese = TranscriptComparison.compare(
        [seg(0, 4, "我们明天开会然后讨论预算")],
        [seg(0, 2, "我们后天开会。"), seg(2, 4, "然后讨论预算。")]
    )
    #expect(chinese.map(\.kind) == [.diverge])
    #expect(chinese.first?.secondaryText == "我们后天开会。然后讨论预算。")
}

@Test("A sliver of overlap is no counterpart: a line the other engine dropped is offered nothing to replace (F572)")
func comparisonTreatsASliverAsNoCounterpart() {
    // The other engine heard nothing at 5.0–5.5; its previous sentence — long, 2 s — runs 50 ms into
    // the line. A SHORT straddling segment would still pair (F658).
    let spans = TranscriptComparison.compare(
        [seg(5.0, 5.5, "Yes.")],
        [seg(3.0, 5.05, "so anyway we are done"), seg(6.0, 7.0, "Next item.")]
    )
    #expect(spans.map(\.kind) == [.nonOverlapping])
    #expect(spans.first?.secondaryText == nil)
}

// F542 — the comparison scanned every segment of the other transcript for every line: 36 million
// pair checks for a six-hour meeting, on the main actor. `compare` now finds each line's counterpart
// through an index in one pass; the plain scan stays as `referenceCompare`, and this holds the fast
// path to it on random transcripts built to hit the awkward cases: ties and touching boundaries on a
// coarse grid, zero-length and reversed spans, a missing start or end, NaN and infinite timestamps,
// texts that normalise the same ("Yes." / "yes"), Chinese, empty text, and lists out of time order.

/// A deterministic generator (SplitMix64), so a failure names a round that can be re-run.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private let randomTexts = [
    "Yes.", "yes", "YES!", "no", "We ship on Friday.", "we ship on friday", "Then we review.",
    "我们明天开会。", "我们明天开会", "然后讨论预算。", "", "…", "Zoom 开会", "ok",
]

private func randomTime(_ rng: inout SplitMix, scale: Double) -> Double? {
    switch rng.below(40) {
    case 0: return nil
    case 1: return .nan
    case 2: return .infinity
    case 3: return -.infinity
    default: return Double(rng.below(25)) * scale   // a coarse grid, so ties and touching ends are common
    }
}

private func randomTranscript(_ rng: inout SplitMix, count: Int, scale: Double) -> [TranscriptSegment] {
    (0..<count).map { _ in
        let start = randomTime(&rng, scale: scale)
        // Mostly a real span after the start; sometimes zero-length, reversed, or independent.
        let end: Double?
        switch rng.below(6) {
        case 0: end = start
        case 1: end = randomTime(&rng, scale: scale)
        default: end = start.map { $0 + Double(1 + rng.below(8)) * scale }
        }
        return TranscriptSegment(speaker: nil, start: start, end: end, text: randomTexts[rng.below(randomTexts.count)])
    }
}

@Test("The one-pass comparison finds exactly what the simple scan finds, on thousands of random transcripts (F542)")
func comparisonFastPathMatchesTheReference() {
    var rng = SplitMix(state: 0x5EC0_4D0B)
    var mismatches = 0
    // Many small transcripts, where the edge cases collide often, then fewer large ones, where the
    // tree is several levels deep.
    let shapes: [(rounds: Int, maxCount: Int, scale: Double)] = [(4_000, 12, 0.5), (60, 400, 0.25)]
    for shape in shapes {
        for round in 0..<shape.rounds {
            let primary = randomTranscript(&rng, count: rng.below(shape.maxCount + 1), scale: shape.scale)
            let secondary = randomTranscript(&rng, count: rng.below(shape.maxCount + 1), scale: shape.scale)
            let texts = primary.map { TranscriptComparison.normalize($0.text) }
            let fast = TranscriptComparison.counterparts(primary, texts, secondary)
            let reference = TranscriptComparison.referenceCounterparts(primary, texts, secondary)
            // Rows, too: kind and offered text. (Whole spans cannot be compared with `==` when a
            // start is NaN, which never equals itself.)
            let fastRows = TranscriptComparison.compare(primary, secondary).map { "\($0.kind) \($0.secondaryText ?? "-")" }
            let referenceRows = TranscriptComparison.referenceCompare(primary, secondary).map { "\($0.kind) \($0.secondaryText ?? "-")" }
            if fast != reference || fastRows != referenceRows {
                mismatches += 1
                if mismatches <= 3 {
                    Issue.record("round \(round) of \(shape.maxCount)-line transcripts: fast \(fast) vs reference \(reference)")
                }
            }
        }
    }
    #expect(mismatches == 0)
}

// PINNED AS IS, NOT AS INTENDED, until F658: both rows offer the whole shared segment, so a Replace
// on either writes the other line's sentence a second time. This is what F472 did too; the test
// keeps F572 from changing it silently, and F658 replaces this expectation.
@Test("Two lines the other engine heard as one each offer the whole shared segment — the duplication F658 fixes (F572 control)")
func comparisonOffersASharedSegmentToBothLinesUntilF658() {
    let spans = TranscriptComparison.compare(
        [seg(10, 13, "We ship on Friday."), seg(13, 18, "Then we review the numbrs.")],
        [seg(10, 18, "We ship on Friday. Then we review the numbers.")]
    )
    #expect(spans.map(\.kind) == [.diverge, .diverge])
    let expected: [String?] = [
        "We ship on Friday. Then we review the numbers.", "We ship on Friday. Then we review the numbers.",
    ]
    #expect(spans.map(\.secondaryText) == expected)
}
