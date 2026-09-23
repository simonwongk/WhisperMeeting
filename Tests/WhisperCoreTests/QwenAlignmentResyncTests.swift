import Foundation
import Testing
@testable import WhisperCore

// F420 — one mismatched sentence untimed the rest of a Qwen meeting.
//
// `QwenAlignedTranscript.segments` assembled aligner words one at a time until they spelled the
// sentence, and gave up as soon as they stopped being a prefix of it. When a sentence boundary fell
// INSIDE an aligner word, that word was consumed by the failing sentence, so the next sentence
// started from the word after it, failed on its first word, consumed one, and so on: the item
// cursor fell further behind with every sentence and never caught up. F263's comment said a later
// sentence would re-sync; in the ticket's exhibits none did — no sentence after the first failure
// was timed.
//
// The trigger in both exhibits was the splitter cutting at a `.` inside a word — an abbreviation
// like "A.D.," cut into "… A." / "D." / ", …", and a domain like "Example.com." cut into
// "… Example." / "com." — while the aligner reports one word. The fixtures below are synthetic
// stand-ins of the same shape; no user transcript text belongs in a fixture.
//
// Fixture fidelity: for English the aligner splits the chunk text on whitespace and keeps only
// Unicode L*/N* characters and the apostrophe of each piece (mlx-audio 0.3.1,
// `stt/models/qwen3_asr/qwen3_forced_aligner.py`: `tokenize_space_lang`, `clean_token`,
// `is_kept_char`), so "B.C.," arrives as the single word "BC" and "think...maybe" as
// "thinkmaybe". `alignerWords` reproduces exactly that for the ASCII text used here.

/// What the forced aligner reports for English text, one `wordSeconds`-long word after another
/// starting at `from`, so every expected timing in this file can be read off a word count.
private func alignerWords(
    _ text: String,
    from start: Double = 0,
    wordSeconds: Double = 0.5
) -> [QwenAlignedItem] {
    var items: [QwenAlignedItem] = []
    var time = start
    for piece in text.split(whereSeparator: \.isWhitespace) {
        let word = String(piece.filter { $0.isLetter || $0.isNumber || $0 == "'" })
        guard !word.isEmpty else { continue }
        items.append(QwenAlignedItem(text: word, start: time, end: time + wordSeconds))
        time += wordSeconds
    }
    return items
}

private func segment(_ segments: [TranscriptSegment], _ text: String) -> TranscriptSegment? {
    segments.first { $0.text == text }
}

// MARK: - (a) an aligner word spanning a sentence boundary

@Test("An abbreviation the aligner reads as one word no longer untimes every later sentence (F420)")
func abbreviationDoesNotUntimeLaterSentences() throws {
    // Words: The old walls stood for a long time (0–7) | They were rebuilt in 44 BC and the city
    // grew again (8–18) | Trade returned within a decade (19–23) | The harbour was dredged twice
    // (24–28) | By then the walls were gone (29–34). Half a second each.
    let text = "The old walls stood for a long time. They were rebuilt in 44 B.C., and the city grew "
        + "again. Trade returned within a decade. The harbour was dredged twice. By then the walls "
        + "were gone."
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: alignerWords(text))

    // Well after the abbreviation — where the old cursor had long since lost its place.
    let later = try #require(segment(segments, "Trade returned within a decade."))
    #expect(later.start == 9.5)
    #expect(later.end == 12.0)
    let last = try #require(segment(segments, "By then the walls were gone."))
    #expect(last.start == 14.5)
    #expect(last.end == 17.5)

    let abbreviated = try #require(segment(segments, "They were rebuilt in 44 B.C., and the city grew again."))
    #expect(abbreviated.start == 4.0)
    #expect(abbreviated.end == 9.5)
    #expect(segments.allSatisfy { $0.start != nil && $0.end != nil })
}

@Test("A domain name the aligner reads as one word no longer untimes every later sentence (F420)")
func domainNameDoesNotUntimeLaterSentences() throws {
    // Words: Hello everyone (0–1) | Welcome back to ExampleLecturesnet (2–5) | Today we look at three
    // old instruments (6–12) | The first is a lute (13–17) | The second is a shawm (18–22) | The
    // third is a small drum (23–28).
    let text = "Hello everyone. Welcome back to ExampleLectures.net. Today we look at three old "
        + "instruments. The first is a lute. The second is a shawm. The third is a small drum."
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: alignerWords(text))

    let today = try #require(segment(segments, "Today we look at three old instruments."))
    #expect(today.start == 3.0)
    #expect(today.end == 6.5)
    let last = try #require(segment(segments, "The third is a small drum."))
    #expect(last.start == 11.5)
    #expect(last.end == 14.5)

    let welcome = try #require(segment(segments, "Welcome back to ExampleLectures.net."))
    #expect(welcome.start == 1.0)
    #expect(welcome.end == 3.0)
    #expect(segments.allSatisfy { $0.start != nil && $0.end != nil })
}

@Test("A sentence that begins inside an aligner word takes that word's timing, and the rest stay timed (F420)")
func boundaryInsideAnAlignerWordStaysTimed() throws {
    // An ellipsis with no space after it is still cut by the splitter: its first two dots are each
    // followed by a dot, which does not count as continuing the sentence, so they end sentences;
    // only the third, followed by a letter, does not. The aligner reports "think...maybe" as ONE word,
    // "thinkmaybe", so "I think." ends inside that word and ".maybe we start…" begins inside it.
    // Both take its timing: it is the same word, not a neighbour's, so the F263 rule that an
    // unmatched sentence never inherits a neighbour's timing is not in play.
    //
    // Words: Good morning everyone (0–2) | I thinkmaybe we start with the budget (3–9) | The venue
    // comes second (10–13) | Catering is last (14–16).
    let text = "Good morning everyone. I think...maybe we start with the budget. The venue comes "
        + "second. Catering is last."
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: alignerWords(text))

    let venue = try #require(segment(segments, "The venue comes second."))
    #expect(venue.start == 5.0)
    #expect(venue.end == 7.0)
    let last = try #require(segment(segments, "Catering is last."))
    #expect(last.start == 7.0)
    #expect(last.end == 8.5)

    let think = try #require(segment(segments, "I think."))
    #expect(think.start == 1.5)
    #expect(think.end == 2.5, "ends with the word it ends inside")
    let maybe = try #require(segment(segments, ".maybe we start with the budget."))
    #expect(maybe.start == 2.0, "starts with the word it starts inside")
    #expect(maybe.end == 5.0)

    // The lone "." between them has no letters to align, so it stays untimed — as before.
    let dot = try #require(segment(segments, "."))
    #expect(dot.start == nil && dot.end == nil)
}

// MARK: - (b) a stretch of sentences the aligner output does not contain

@Test("Sentences whose alignment was dropped stay untimed and the ones after them are timed (F420)")
func droppedChunkUntimesOnlyItsOwnSentences() throws {
    // The helper skips a chunk it cannot slice audio for (`align_chunks`), so its words are simply
    // absent from `alignedItems`. The middle chunk here is that chunk.
    let first = "We opened the meeting at nine. The minutes were approved."
    let dropped = "Next came the budget review. It ran long."
    let third = "Then we discussed the venue. It is booked for May."
    let text = [first, dropped, third].joined(separator: " ")
    let items = alignerWords(first, from: 0) + alignerWords(third, from: 20)

    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    try #require(segments.map(\.text) == [
        "We opened the meeting at nine.", "The minutes were approved.",
        "Next came the budget review.", "It ran long.",
        "Then we discussed the venue.", "It is booked for May.",
    ])
    #expect(segments[0].start == 0.0 && segments[0].end == 3.0)
    #expect(segments[1].start == 3.0 && segments[1].end == 5.0)
    #expect(segments[2].start == nil && segments[2].end == nil)
    #expect(segments[3].start == nil && segments[3].end == nil)
    #expect(segments[4].start == 20.0 && segments[4].end == 22.5)
    #expect(segments[5].start == 22.5 && segments[5].end == 25.0)
}

@Test("A sentence cut in half by a dropped chunk does not stop the next one being found (F420)")
func sentenceSplitAcrossDroppedChunkResyncs() throws {
    // Chunks are cut at quiet points, not at sentence ends, so a dropped chunk can take the first
    // half of a sentence with it. What is left of that sentence ("ran long") then sits in the
    // aligner output ahead of the next sentence, which has to be found past it.
    let first = "We opened the meeting at nine."
    let dropped = "Next came the budget review, which"
    let third = "ran long. Then we discussed the venue. It is booked for May."
    let text = [first, dropped, third].joined(separator: " ")
    let items = alignerWords(first, from: 0) + alignerWords(third, from: 20)

    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    try #require(segments.map(\.text) == [
        "We opened the meeting at nine.",
        "Next came the budget review, which ran long.",
        "Then we discussed the venue.", "It is booked for May.",
    ])
    #expect(segments[0].start == 0.0 && segments[0].end == 3.0)
    #expect(segments[1].start == nil && segments[1].end == nil, "only its second half was aligned, so it gets no timing")
    #expect(segments[2].start == 21.0 && segments[2].end == 23.5)
    #expect(segments[3].start == 23.5 && segments[3].end == 26.0)
}

@Test("Words the aligner has and the transcript lacks do not stop re-sync for good (F420)")
func alignerSurplusIsOvertaken() throws {
    // The helper aligns the same chunk texts it joins into the transcript, so a surplus like this is
    // not expected. It is here because a matcher that cannot get past one would fail exactly as the
    // old one did: every sentence after it untimed, however long the meeting ran on. Each miss moves
    // the next sentence one-for-one further from the cursor, so the search has to widen faster
    // than that or it never arrives.
    let text = "The meeting started late. We covered the roadmap first. Then the budget came up. "
        + "Hiring was last. We ended at noon."
    let surplus = "these words were never in the transcript at all"
    let items = alignerWords(
        "The meeting started late. \(surplus) We covered the roadmap first. Then the budget came "
            + "up. Hiring was last. We ended at noon."
    )
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    // Words: The meeting started late (0–3) | the surplus (4–12) | We covered the roadmap first
    // (13–17) | Then the budget came up (18–22) | Hiring was last (23–25) | We ended at noon (26–29).
    // The sentence straight after the surplus is what the search spends catching up, so it is not
    // asserted; the ones after it are the point.
    try #require(segments.count == 5)
    #expect(segments[0].start == 0.0 && segments[0].end == 2.0)
    #expect(segments[2].text == "Then the budget came up.")
    #expect(segments[2].start == 9.0 && segments[2].end == 11.5)
    #expect(segments[3].start == 11.5 && segments[3].end == 13.0)
    #expect(segments[4].start == 13.0 && segments[4].end == 15.0)
}

// MARK: - (c) a short, common sentence cannot jump the cursor

@Test("A dropped short sentence does not jump ahead to a later identical one (F420)")
func droppedShortSentenceDoesNotJumpAhead() throws {
    // The first two sentences were dropped. The first "Yeah." is not in the aligner output, but a
    // later "yeah" is, a few words ahead. Matching it would push the cursor past "The venue is booked
    // for May." — timing the wrong "Yeah." and leaving the venue sentence with nothing.
    let dropped = "We reviewed the spring budget. Yeah."
    let kept = "The venue is booked for May. Yeah. Catering is still open."
    let text = dropped + " " + kept
    let segments = QwenAlignedTranscript.segments(
        fullText: text,
        alignedItems: alignerWords(kept, from: 10)
    )

    try #require(segments.map(\.text) == [
        "We reviewed the spring budget.", "Yeah.",
        "The venue is booked for May.", "Yeah.", "Catering is still open.",
    ])
    #expect(segments[0].start == nil)
    #expect(segments[1].start == nil && segments[1].end == nil, "the dropped Yeah. has no timing")
    #expect(segments[2].start == 10.0 && segments[2].end == 13.0)
    #expect(segments[3].start == 13.0 && segments[3].end == 13.5, "the kept Yeah. keeps its own")
    #expect(segments[4].start == 13.5 && segments[4].end == 15.5)
}

@Test("A dropped short sentence does not claim the opening word of the next sentence (F420)")
func droppedShortSentenceDoesNotClaimNextSentencesStart() throws {
    // The aligner output starts with "yeah", but that word belongs to "Yeah, the venue is booked.",
    // not to the dropped "Yeah." before it. Taking it would time the wrong sentence and leave the
    // right one with no start.
    let dropped = "Budget first. Yeah."
    let kept = "Yeah, the venue is booked. Catering is open."
    let text = dropped + " " + kept
    let segments = QwenAlignedTranscript.segments(
        fullText: text,
        alignedItems: alignerWords(kept, from: 30)
    )

    try #require(segments.map(\.text) == [
        "Budget first.", "Yeah.", "Yeah, the venue is booked.", "Catering is open.",
    ])
    #expect(segments[0].start == nil)
    #expect(segments[1].start == nil && segments[1].end == nil)
    #expect(segments[2].start == 30.0 && segments[2].end == 32.5)
    #expect(segments[3].start == 32.5 && segments[3].end == 34.0)
}

@Test("A dropped sentence cannot match a repeat of itself far ahead (F420)")
func droppedSentenceCannotMatchADistantRepeat() throws {
    // The opening "Let us begin." was dropped, and the same two sentences recur at the end. A search
    // with no bound would match the repeat — the sentence after it even agrees — and leave
    // everything in between untimed.
    let text = "Let us begin. Slide one please. The first quarter was slow. Sales picked up in "
        + "April. Costs stayed flat all year. Hiring resumed in the autumn. Let us begin. Slide one "
        + "please."
    let kept = String(text.dropFirst("Let us begin. ".count))
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: alignerWords(kept))

    // Words: Slide one please (0–2) | The first quarter was slow (3–7) | Sales picked up in April
    // (8–12) | Costs stayed flat all year (13–17) | Hiring resumed in the autumn (18–22) | Let us
    // begin (23–25) | Slide one please (26–28).
    try #require(segments.count == 8)
    #expect(segments[0].text == "Let us begin.")
    #expect(segments[0].start == nil && segments[0].end == nil)
    #expect(segments[1].start == 0.0 && segments[1].end == 1.5)
    #expect(segments[2].start == 1.5 && segments[2].end == 4.0)
    #expect(segments[5].start == 9.0 && segments[5].end == 11.5)
    #expect(segments[6].text == "Let us begin.")
    #expect(segments[6].start == 11.5 && segments[6].end == 13.0)
    #expect(segments[7].start == 13.0 && segments[7].end == 14.5)
}

// MARK: - (d) the splitter

@Test("The splitter does not cut inside A.D.-style abbreviations, domains or decimals (F420)")
func splitterKeepsWordInternalPunctuationTogether() {
    let text = "They were rebuilt in 44 B.C., and the city grew. Visit ExampleLectures.net for "
        + "notes. The ratio was 3.5 to one. Really? Yes!"
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: alignerWords(text))

    #expect(segments.map(\.text) == [
        "They were rebuilt in 44 B.C., and the city grew.",
        "Visit ExampleLectures.net for notes.",
        "The ratio was 3.5 to one.",
        "Really?",
        "Yes!",
    ])
    #expect(segments.allSatisfy { $0.start != nil && $0.end != nil })
}

@Test("Chinese sentence ends are cut exactly as before (F420 regression guard)")
func splitterCutsChineseAsBefore() throws {
    // The aligner makes every CJK ideograph its own word (`tokenize_chinese_mixed`,
    // `split_segment_with_chinese`), so a cut in front of one can never fall inside a word — and
    // Chinese puts no space after a sentence, so not cutting there would merge whole passages. That
    // holds for an ASCII `.` too.
    let text = "我们开始吧。今天讨论预算？好的.下一个"
    let items = Array("我们开始吧今天讨论预算好的下一个").enumerated().map { index, character in
        QwenAlignedItem(text: String(character), start: Double(index) * 0.25, end: Double(index + 1) * 0.25)
    }
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    try #require(segments.map(\.text) == ["我们开始吧。", "今天讨论预算？", "好的.", "下一个"])
    #expect(segments[0].start == 0.0 && segments[0].end == 1.25)
    #expect(segments[3].start == 3.25 && segments[3].end == 4.0)
}

// MARK: - (e) the zero-reconciliation contract

@Test("When no sentence can be placed anywhere the result is still empty (F420 regression guard)")
func noPlacementStillReturnsNoSegments() {
    // F30's warning and the caller's fallback to the raw transcript key off an empty result. The
    // forward search must not turn a total mismatch into a handful of chance matches.
    let segments = QwenAlignedTranscript.segments(
        fullText: "Alpha beta gamma. Delta epsilon. Zeta eta theta.",
        alignedItems: alignerWords("Completely unrelated words from somewhere else entirely")
    )
    #expect(segments.isEmpty)
}
