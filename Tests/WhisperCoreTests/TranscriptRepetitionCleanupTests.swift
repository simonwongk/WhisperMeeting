import Foundation
import Testing
@testable import WhisperCore

// F422 — what a stuck decode leaves behind is removed, not just flagged. The exhibit is the user's
// lecture at 27:51: Qwen looped on `操！`, F260's guard stopped it at sixteen copies, sentence slicing
// made each copy its own zero-length line, and neither F186 (one line dominating half the
// transcript) nor F261 (a unit repeated twenty times inside ONE line) could see sixteen lines out of
// 433. The rest of the user's library had the same shape as `嗯。` ×51, `Yeah.` ×17 and `Bye.` ×21.

private func line(_ text: String, _ start: Double?, _ end: Double?) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("A run of identical lines keeps its first line, with that line's own timing (F422, F426)")
func aRunOfIdenticalLinesIsReducedToOne() {
    // The exhibit's shape: sixteen copies, their timestamps crushed into two seconds.
    var segments = [
        line("认识认识他，然后认识认识他。", 1647.5, 1665.7),
        line("但你都不认识。", 1668.8, 1669.7),
    ]
    for copy in 0..<16 {
        let at = 1670.6 + Double(copy) * 0.13
        segments.append(line("操！", at, at + 0.1))
    }
    segments.append(line("The question might ask you like what is going there.", 1706.7, 1718.3))

    let result = TranscriptRepetitionCleanup.clean(segments)

    #expect(result.segments.map(\.text) == [
        "认识认识他，然后认识认识他。",
        "但你都不认识。",
        "操！",
        "The question might ask you like what is going there.",
    ])
    #expect(result.removedCount == 15)
    // The surviving line is the first copy, timed as the recognizer timed it — not stretched over
    // the loop, which would move a line and make an existing speaker analysis read stale (F426).
    let kept = result.segments[2]
    let firstCopyEnd: Double = 1670.6 + 0.1
    #expect(kept.start == 1670.6)
    #expect(kept.end == firstCopyEnd)
}

@Test("Lines that differ only in case or punctuation are the same line (F422)")
func punctuationAndCaseDoNotHideARun() {
    let segments = [
        line("Yeah.", 101, 102), line("yeah", 103, 104), line("Yeah!", 105, 106), line("YEAH.", 107, 108),
    ]
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments.map(\.text) == ["Yeah."])
    #expect(result.removedCount == 3)
}

@Test("Three identical lines in a row are real speech and are kept (F422)")
func threeInARowIsKept() {
    // "Bye. Bye. Bye." at the end of a call is what people say. The bar is four.
    let segments = [line("Bye.", 1, 2), line("Bye.", 2, 3), line("Bye.", 3, 4), line("Take care.", 4, 5)]
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == segments)
    #expect(result.removedCount == 0)
}

@Test("Identical lines that are not consecutive are never merged (F422)")
func interleavedRepeatsAreKept() {
    var segments: [TranscriptSegment] = []
    for index in 0..<8 {
        segments.append(line(index.isMultiple(of: 2) ? "嗯。" : "对，然后呢？", Double(index), Double(index) + 1))
    }
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == segments)
    #expect(result.removedCount == 0)
}

@Test("Lines with no letters or digits are never treated as a run (F422)")
func punctuationOnlyLinesAreKept() {
    let segments = (0..<5).map { line("…", Double($0), Double($0) + 1) }
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == segments)
    #expect(result.removedCount == 0)
}

@Test("A unit repeated ten or more times inside a line keeps one copy (F422)")
func anInlineRunKeepsOneCopy() {
    // F261's CJK exhibit had `他们，` 4,006 times inside one segment. The words around the run are
    // real and must survive.
    let text = "我说" + String(repeating: "他们，", count: 4_006) + "然后走了。"
    let result = TranscriptRepetitionCleanup.clean([line(text, 542, 548)])
    #expect(result.segments.map(\.text) == ["我说他们，然后走了。"])
    #expect(result.removedCount == 4_005)
}

@Test("A space-delimited inline loop reads as speech afterwards (F422)")
func aSpaceDelimitedInlineRunReadsCleanly() {
    // The shortest repeating unit starts one character in ("o, n"), because "No, " and "no, " differ
    // in case. What matters is what the reader sees.
    let text = "No, " + String(repeating: "no, ", count: 30) + "no."
    let result = TranscriptRepetitionCleanup.clean([line(text, 0, 6)])
    #expect(result.segments.map(\.text) == ["No, no."])
    #expect(result.removedCount == 30)
}

@Test("Nine repeats inside a line are real speech and are kept (F422)")
func nineInlineRepeatsAreKept() {
    let laughter = line("哈哈哈哈哈哈哈哈哈，太好笑了。", 0, 2)
    let blah = line("And then blah blah blah blah blah blah blah blah blah and so on.", 2, 6)
    let result = TranscriptRepetitionCleanup.clean([laughter, blah])
    #expect(result.segments == [laughter, blah])
    #expect(result.removedCount == 0)
}

@Test("A run of digits is a number, never a loop (F422)")
func digitsAreNeverCollapsed() {
    let segments = [line("It costs 10000000000000 dollars, and the code is 0000000000.", 0, 3)]
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == segments)
    #expect(result.removedCount == 0)
}

@Test("A healthy transcript comes back unchanged, byte for byte (F422)")
func aHealthyTranscriptIsUntouched() {
    let segments = [
        line("  Leading space is the recognizer's, not ours.", 0, 2),
        line("So FDI is basically if the company has operations.", 2, 4),
        line("我们下周一有个小测验。", 4, 6),
        line("No, no, no.", 6, 7),
    ]
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == segments)
    #expect(result.removedCount == 0)
}

@Test("Inline loops collapse before lines are compared, so looping lines become one line (F422)")
func inlineThenLineCleanupCompose() {
    let looping = "Okay, " + String(repeating: "okay, ", count: 12) + "okay."
    let segments = (0..<5).map { line(looping, Double($0), Double($0) + 1) } + [line("Next topic.", 5, 6)]
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments.map(\.text) == ["Okay, okay.", "Next topic."])
    // Twelve in-line copies from each of five lines, then four whole lines.
    #expect(result.removedCount == 5 * 12 + 4)
}

@Test("An untimed run keeps its first line untimed rather than borrowing a time (F422)")
func anUntimedRunStaysUntimed() {
    let segments = (0..<4).map { _ in line("嗯。", nil, nil) }
    let result = TranscriptRepetitionCleanup.clean(segments)
    #expect(result.segments == [line("嗯。", nil, nil)])
    #expect(result.removedCount == 3)
}

@Test("Untimed text has its inline loops removed the same way (F422)")
func plainTextInlineRunsCollapse() {
    // The Qwen fallback when alignment fails entirely: one block of text, no lines to compare.
    let text = "但你都不认识。" + String(repeating: "操！", count: 16) + "The question might ask you."
    let result = TranscriptRepetitionCleanup.cleanText(text)
    #expect(result.text == "但你都不认识。操！The question might ask you.")
    #expect(result.removedCount == 15)
    #expect(TranscriptRepetitionCleanup.cleanText("Nothing to do here.").text == "Nothing to do here.")
    #expect(TranscriptRepetitionCleanup.cleanText("Nothing to do here.").removedCount == 0)
}

@Test("The notices count copies in plain words, singular and plural (F422)")
func theNoticesReadCorrectly() {
    #expect(TranscriptRepetitionCleanup.removableNotice(count: 15) == "This transcript has 15 repeated copies of a phrase the recognizer got stuck on. Removing them keeps the first one; the recording is unchanged.")
    #expect(TranscriptRepetitionCleanup.removableNotice(count: 1) == "This transcript has 1 repeated copy of a phrase the recognizer got stuck on. Removing it keeps the first one; the recording is unchanged.")
    #expect(TranscriptRepetitionCleanup.removedNote(count: 4_005) == "4005 repeated copies of a phrase the recognizer got stuck on were removed, keeping the first. The recording is unchanged.")
    #expect(TranscriptRepetitionCleanup.removedNote(count: 1) == "1 repeated copy of a phrase the recognizer got stuck on was removed, keeping the first. The recording is unchanged.")
}
