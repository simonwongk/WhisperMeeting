import Foundation
import Testing
@testable import WhisperCore

// F263 — Qwen timestamp alignment was all-or-nothing.
//
// `QwenAlignedTranscript.segments` returned `[]` from any of seven guards, so a single
// character-level mismatch anywhere in a 60-minute meeting discarded EVERY timestamp: with no
// segments, `TranscriptFormatter.timestamped` falls back on `guard let start` and emits bare text
// for every line. That is the user-reported "why sometimes no timestamp" — and it is Qwen-only,
// because Whisper always emits per-segment start/end.
//
// Keeping the complete text was the right instinct; the granularity was wrong. A sentence that
// cannot be reconciled is now emitted untimed while its neighbours keep their timings.
//
// Hard constraint: an unmatched sentence carries **nil**, never a neighbour's timing. Inheriting one
// makes the transcript seek to the wrong place, which is worse than having no timestamp at all.

private func item(_ text: String, _ start: Double, _ end: Double) -> QwenAlignedItem {
    QwenAlignedItem(text: text, start: start, end: end)
}

@Test("A sentence that cannot be reconciled no longer discards its neighbours' timestamps (F263)")
func partialAlignmentKeepsGoodTimestamps() {
    let text = "One two. Three four. Five six."
    let items = [
        item("One", 0.0, 0.5), item("two.", 0.5, 1.0),
        item("mismatching", 1.0, 1.5),               // cannot assemble "Three four."
        item("Five", 2.0, 2.5), item("six.", 2.5, 3.0)
    ]

    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    #expect(segments.count == 3, "every sentence must still be present")
    #expect(segments[0].text == "One two.")
    #expect(segments[0].start == 0.0)
    #expect(segments[0].end == 1.0)

    // The unreconcilable one: present, complete, and explicitly untimed.
    #expect(segments[1].text == "Three four.")
    #expect(segments[1].start == nil, "it must not inherit a neighbour's start")
    #expect(segments[1].end == nil, "it must not inherit a neighbour's end")

    #expect(segments[2].text == "Five six.")
    #expect(segments[2].start == 2.0)
    #expect(segments[2].end == 3.0)
}

@Test("No words are dropped when alignment partially fails (F263)")
func partialAlignmentDropsNoText() {
    let text = "One two. Three four. Five six."
    let items = [
        item("One", 0.0, 0.5), item("two.", 0.5, 1.0),
        item("mismatching", 1.0, 1.5),
        item("Five", 2.0, 2.5), item("six.", 2.5, 3.0)
    ]
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)
    // The original guarantee this weakens is "complete text preserved"; hold it exactly.
    #expect(segments.map(\.text).joined(separator: " ") == text)
}

@Test("Leftover trailing aligned items no longer discard every timestamp (F263)")
func leftoverItemsDoNotDiscardEverything() {
    // The old final guard, `itemIndex == alignedItems.count`, threw the whole transcript away when
    // the aligner emitted one item more than the text accounted for.
    let text = "Hello world."
    let items = [item("Hello", 0.0, 0.5), item("world.", 0.5, 1.0), item("extra", 1.0, 1.5)]

    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)
    #expect(segments.count == 1)
    #expect(segments[0].start == 0.0)
    #expect(segments[0].end == 1.0)
}

@Test("A combining mark the aligner strips no longer breaks reconciliation (F263)")
func combiningMarkReconciles() {
    // Proven trigger, read from the installed aligner: `is_kept_char` keeps only Unicode categories
    // L* and N* (plus an apostrophe) — `qwen3_forced_aligner.py:23-30` — so it strips M* marks from
    // its token text. Swift's `CharacterSet.alphanumerics` is L* + M* + N*, so our key kept a mark
    // the aligner had already removed and the two could never match.
    //
    // U+0301 on "x" has no precomposed form, so Swift's canonical equivalence cannot paper over it.
    let text = "ox\u{0301}y here."
    let items = [item("oxy", 0.0, 0.5), item("here.", 0.5, 1.0)]

    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)
    #expect(segments.count == 1, "the sentence should reconcile now that marks are filtered")
    #expect(segments[0].start == 0.0)
    #expect(segments[0].end == 1.0)
}

@Test("A fully reconcilable transcript is unchanged (F263 regression guard)")
func fullAlignmentUnchanged() {
    let text = "Alpha beta. Gamma delta."
    let items = [
        item("Alpha", 0.0, 0.5), item("beta.", 0.5, 1.0),
        item("Gamma", 1.0, 1.5), item("delta.", 1.5, 2.0)
    ]
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)

    #expect(segments.count == 2)
    #expect(segments.allSatisfy { $0.start != nil && $0.end != nil })
    #expect(segments[0].start == 0.0 && segments[0].end == 1.0)
    #expect(segments[1].start == 1.0 && segments[1].end == 2.0)
}

@Test("When nothing reconciles at all the result is still empty, as F30 expects (F263)")
func totalFailureStillReturnsNoSegments() {
    // F30's warning keys off `segments.isEmpty` for the total-failure case, and four of its tests
    // assert it. Partial recovery must not change that contract — only add to it.
    let segments = QwenAlignedTranscript.segments(
        fullText: "Kubernetes powers the cluster.",
        alignedItems: [item("totally", 0.0, 0.5), item("different", 0.5, 1.0)]
    )
    #expect(segments.isEmpty)
}

@Test("A partly-timed transcript is described truthfully, not as 'unavailable' (F263)")
func partialAlignmentWarningIsTruthful() {
    let text = "One two. Three four. Five six."
    let items = [
        item("One", 0.0, 0.5), item("two.", 0.5, 1.0),
        item("mismatching", 1.0, 1.5),
        item("Five", 2.0, 2.5), item("six.", 2.5, 3.0)
    ]
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)
    let payload = QwenOutput(text: text, language: "en", alignedItems: items, alignmentWarning: nil)

    let warning = QwenASRClient.alignmentWarning(text: text, segments: segments, payload: payload)
    // It must not claim timestamps are unavailable over a transcript that is mostly seekable …
    #expect(warning != nil, "the user should still learn that one passage has no timestamp")
    #expect(warning?.contains("unavailable") == false)
    #expect(warning?.contains("1") == true, "say how many passages lost their timing")
}

@Test("A fully timed transcript still carries no warning (F263)")
func fullyTimedTranscriptHasNoWarning() {
    let text = "Alpha beta. Gamma delta."
    let items = [
        item("Alpha", 0.0, 0.5), item("beta.", 0.5, 1.0),
        item("Gamma", 1.0, 1.5), item("delta.", 1.5, 2.0)
    ]
    let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: items)
    let payload = QwenOutput(text: text, language: "en", alignedItems: items, alignmentWarning: nil)

    #expect(QwenASRClient.alignmentWarning(text: text, segments: segments, payload: payload) == nil)
}
