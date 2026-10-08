import Testing
@testable import WhisperCore

// F873 — F287 (`9bfd595`, 2026-09-17) changed `TranscriptFormatter.timestamp` from rounding DOWN to
// rounding to the nearest second. A meeting transcribed before that keeps the text it was written
// with, so a line starting at 30.7 s reads "00:30" in it while today's rendering says "00:31" — and
// `isEdited`, which compares the two, called every untouched multi-line meeting from before that day
// hand-edited: quality flags hidden, the Improve tools "Unavailable after manual edits", and since
// F455/F837 Ask and the action-item quotes reading the lines instead of the segments.
//
// The fixture text below is written out by hand in the pre-F287 format (`String(format: "%02d:%02d",
// total / 60, total % 60)` of `max(0, Int(seconds))`), not produced by today's code. Stored text is
// never rewritten; the comparisons accept both renderings.

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 4, text: text, avgLogprob: -0.2)
}

private let segments = [
    seg(30.7, "We'll ship on Friday."),
    seg(35.2, "Sounds good."),
    seg(75.9, "Next item is hiring."),
]

/// How a build before F287 wrote these segments: every start rounded down.
private let writtenBeforeF287 = "00:30  We'll ship on Friday.\n00:35  Sounds good.\n01:15  Next item is hiring."

@Test("An untouched transcript written before F287 reads as unedited (F873)")
func preF287TranscriptIsUnedited() throws {
    // The precondition: today's rendering differs from what was stored, which is the whole defect.
    try #require(TranscriptFormatter.timestamped(segments) != writtenBeforeF287)
    #expect(!TranscriptFormatter.isEdited(transcriptText: writtenBeforeF287, segments: segments))
    #expect(!TranscriptFormatter.isEdited(transcriptText: writtenBeforeF287 + "\n", segments: segments))
    // And everything that reads "the transcript as the user left it" gets the segments, timings and all.
    #expect(EditedTranscript.effectiveSegments(transcriptText: writtenBeforeF287, segments: segments) == segments)
}

@Test("A real edit of a pre-F287 transcript still reads as edited, and so does clearing it (F873, F837)")
func preF287EditIsStillAnEdit() {
    let corrected = writtenBeforeF287.replacingOccurrences(of: "Sounds good.", with: "Sounds great.")
    #expect(TranscriptFormatter.isEdited(transcriptText: corrected, segments: segments))
    let lineDeleted = "00:30  We'll ship on Friday.\n01:15  Next item is hiring."
    #expect(TranscriptFormatter.isEdited(transcriptText: lineDeleted, segments: segments))
    #expect(TranscriptFormatter.isEdited(transcriptText: "", segments: segments))
    // Today's rendering is of course still unedited.
    #expect(!TranscriptFormatter.isEdited(transcriptText: TranscriptFormatter.timestamped(segments), segments: segments))
}

@Test("A correction inside a pre-F287 transcript keeps each line's precise timing (F873)")
func preF287CorrectionKeepsPreciseTimings() {
    let corrected = writtenBeforeF287.replacingOccurrences(of: "Sounds good.", with: "Sounds great.")
    let effective = EditedTranscript.effectiveSegments(transcriptText: corrected, segments: segments)
    #expect(effective.map(\.text) == ["We'll ship on Friday.", "Sounds great.", "Next item is hiring."])
    let starts: [Double?] = [30.7, 35.2, 75.9]
    #expect(effective.map(\.start) == starts, "the lines still align with the segments they were written from")
}

@Test("SRT of an untouched pre-F287 transcript keeps each cue's own timing (F873)")
func preF287SubtitlesKeepPreciseTimings() {
    let srt = TranscriptExporter.render(.srt, TranscriptExportRequest(
        title: "t", languageCode: "en", durationSeconds: 90, transcriptText: writtenBeforeF287, segments: segments
    ))
    #expect(srt.contains("00:00:30,700 --> 00:00:34,700"), "\(srt)")
    #expect(srt.contains("00:01:15,900 --> 00:01:19,900"), "\(srt)")
}
