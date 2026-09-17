import Foundation
import Testing
@testable import WhisperCore

// F261 — a degenerate run packed INSIDE one segment.
//
// F186 (`TranscriptRepetitionTests.swift`) counts line occurrences, so it only sees a loop spread
// across many lines. Qwen produces the other shape: the loop lands in a single segment, because
// `QwenAlignedTranscript.sentenceSlices` does not treat a comma as a sentence terminator, so a run
// of "No, no, no, …" never ends a sentence and never starts a new one.
//
// The real exhibit is one segment spanning 01:55→02:01 — six seconds of audio — holding `"No, "`
// repeated 4,034 times, which is roughly 8,000 tokens, i.e. Qwen's greedy decode ran to its
// `ASR_MAX_TOKENS` ceiling (fixed at source by F260). In that transcript dominance is 1/65 = 0.015,
// far under F186's 0.5 bar, so the transcript-level notice stayed silent; the per-segment flag did
// fire but only reaches the quality review, not the banner.

private func runSeg(_ index: Int, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: Double(index), end: Double(index) + 1, text: text)
}

@Test("A unit repeated thousands of times inside one segment is found (F261)")
func findsDegenerateRunInsideASegment() {
    let run = TranscriptQuality.degenerateRun(in: String(repeating: "No, ", count: 4_034))
    #expect(run?.unit == "No, ")
    #expect(run?.repeats == 4_034)
}

@Test("A CJK loop with no word boundaries is found too (F261)")
func findsCJKDegenerateRun() {
    // The user's Mandarin report: 他们，他们，他们… — no spaces, and `，` is not a terminator either.
    let run = TranscriptQuality.degenerateRun(in: String(repeating: "他们，", count: 400))
    #expect(run?.unit == "他们，")
    #expect(run?.repeats == 400)
}

@Test("Ordinary prose contains no degenerate run (F261)")
func proseHasNoDegenerateRun() {
    let text = "We should ship the migration on Tuesday, then review the rollout notes together."
    #expect(TranscriptQuality.degenerateRun(in: text) == nil)
}

@Test("Genuine speech repetition is not a degenerate run (F261)")
func genuineRepetitionIsNotADegenerateRun() {
    // "No, no, no." is a real thing a person says. Only a machine says it twenty times running.
    #expect(TranscriptQuality.degenerateRun(in: "No, no, no.") == nil)
    #expect(TranscriptQuality.degenerateRun(in: "对，对，对，对，对。") == nil)
}

@Test("A run that real speech interrupted is still reported (F261)")
func runFollowedByRealSpeechIsStillReported() {
    // The observed loop ended with a short real sentence after it; trailing words must not hide the
    // run. Synthetic stand-in — no user transcript content belongs in a fixture (AGENTS.md).
    let text = String(repeating: "No, ", count: 4_034) + "Va bene allora."
    #expect(TranscriptQuality.degenerateRun(in: text)?.repeats == 4_034)
}

@Test("The transcript notice fires for a loop inside a single segment (F261)")
func noticeFiresForSingleSegmentLoop() {
    // The real exhibit's shape: 65 lines, exactly ONE of which is the loop.
    var segments = (0..<64).map { runSeg($0, "Una frase normale numero \($0).") }
    segments.insert(runSeg(41, String(repeating: "No, ", count: 4_034)), at: 41)
    #expect(segments.count == 65)

    let notice = TranscriptQuality.repetitionNotice(segments)
    #expect(notice != nil, "a 4,034× run inside one segment was not flagged")
    // 4,033 and not 4,034: `repetitionNotice` trims each line, which removes the run's final space,
    // so the last `"No, "` block is incomplete and does not count. The count is still the thing the
    // user needs, so assert it is reported and is the honest one for the trimmed text.
    #expect(notice?.contains("4033") == true,
            "the notice should say how many times the unit repeated")
    #expect(notice?.contains("No,") == true, "the notice should quote the repeated unit")
}

@Test("A single looping segment is flagged even on a short transcript (F261)")
func noticeFiresOnShortTranscriptWithLoop() {
    // F186 refuses to judge fewer than 20 lines, and rightly so — dominance needs evidence. A run of
    // 4,034 identical units inside ONE line needs none: it is self-evidently not speech.
    let segments = [
        runSeg(0, "Allora, cominciamo."),
        runSeg(1, String(repeating: "No, ", count: 4_034)),
        runSeg(2, "Va bene.")
    ]
    #expect(TranscriptQuality.repetitionNotice(segments) != nil)
}

@Test("A healthy short transcript is still never flagged (F261 must not weaken F186)")
func healthyShortTranscriptStillUnflagged() {
    let segments = (0..<6).map { runSeg($0, "好的") }
    #expect(TranscriptQuality.repetitionNotice(segments) == nil)
}

@Test("A loop long enough to matter is caught at the threshold, not below it (F261)")
func degenerateRunThresholdBoundary() {
    let minimum = TranscriptQuality.degenerateRunMinimumRepeats
    #expect(TranscriptQuality.degenerateRun(in: String(repeating: "ok ", count: minimum - 1)) == nil)
    #expect(TranscriptQuality.degenerateRun(in: String(repeating: "ok ", count: minimum))?.repeats == minimum)
}
