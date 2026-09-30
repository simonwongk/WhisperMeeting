import Foundation
import Testing
@testable import WhisperCore

// F183 — captions → segments. They are stored as `MeetingRecord.referenceSegments`, which nothing shows
// yet (F491), but the parser still strips speaker labels (no-diarization invariant) so no future path
// can carry speaker identity into a transcript, and collapses rolling-caption duplicates.

@Test("Parses WebVTT cues into timed segments, ignoring header and cue settings (F183)")
func parsesWebVTT() {
    let vtt = """
    WEBVTT

    00:00:00.000 --> 00:00:02.500 align:start position:0%
    Hello there.

    00:00:02.500 --> 00:00:05.000
    Second line.
    """
    let segments = SubtitleParser.parse(vtt)
    #expect(segments.count == 2)
    #expect(segments[0].start == 0)
    #expect(segments[0].end == 2.5)
    #expect(segments[0].text == "Hello there.")
    #expect(segments[1].start == 2.5)
    #expect(segments[1].text == "Second line.")
}

@Test("Parses SRT (comma milliseconds, numeric index lines) (F183)")
func parsesSRT() {
    let srt = """
    1
    00:00:01,000 --> 00:00:03,000
    From SRT.

    2
    00:00:03,000 --> 00:00:04,500
    Another.
    """
    let segments = SubtitleParser.parse(srt)
    #expect(segments.count == 2)
    #expect(segments[0].start == 1)
    #expect(segments[0].text == "From SRT.")
}

@Test("Strips inline timing/color/voice tags from cue text (F183)")
func stripsInlineTags() {
    let vtt = """
    WEBVTT

    00:00:00.000 --> 00:00:02.000
    <00:00:00.000><c> Kubernetes</c> <v Alice>runs it</v>
    """
    #expect(SubtitleParser.parse(vtt).first?.text == "Kubernetes runs it")
}

@Test("Strips speaker labels so no speaker identity enters a segment (no-diarization invariant, F183)")
func stripsSpeakerLabels() {
    func text(_ cue: String) -> String? {
        SubtitleParser.parse("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n\(cue)").first?.text
    }
    #expect(text(">> JOHN: Good morning.") == "Good morning.")
    #expect(text("[Speaker 1] Over here.") == "Over here.")
    #expect(text("- Yes, exactly.") == "Yes, exactly.")
    #expect(text("ANNOUNCER: Welcome.") == "Welcome.")
}

@Test("Collapses rolling-caption duplicates instead of doubling the reference (F183)")
func collapsesRollingDuplicates() {
    // YouTube auto-captions re-emit the same line across consecutive cues with shifting timings.
    let vtt = """
    WEBVTT

    00:00:00.000 --> 00:00:01.000
    we agreed on the

    00:00:01.000 --> 00:00:02.000
    we agreed on the budget

    00:00:02.000 --> 00:00:03.000
    we agreed on the budget
    """
    let segments = SubtitleParser.parse(vtt)
    #expect(segments.count == 1)
    #expect(segments[0].text == "we agreed on the budget")
    #expect(segments[0].end == 3) // end extended across the collapsed run
}

// F491 — WebVTT (and TranscriptExporter's own SRT) carry `<`, `>` and `&` as character references.
// Label stripping is anchored on a literal `>>`, so an escaped chevron used to slip past it whole.
@Test("Strips a speaker label whose chevrons arrive entity-escaped (no-diarization invariant, F491)")
func stripsEntityEscapedSpeakerLabels() {
    func text(_ cue: String) -> String? {
        SubtitleParser.parse("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n\(cue)").first?.text
    }
    #expect(text("&gt;&gt; JOHN: Good morning.") == "Good morning.")
    #expect(text("&gt;&gt; and then we shipped") == "and then we shipped")
}

@Test("Captions TranscriptExporter writes as VTT and SRT parse back to the original text (F491)")
func roundTripsTranscriptExporterCueText() {
    // `&`, `<`, `>` and `-->` are what the exporter escapes (F44). A decoded `<b>` is text, not a tag.
    func roundTrip(_ format: TranscriptExportFormat, _ original: String) -> [String] {
        let request = TranscriptExportRequest(
            title: "t",
            languageCode: "en",
            durationSeconds: 2,
            transcriptText: original,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: original)]
        )
        return SubtitleParser.parse(TranscriptExporter.render(format, request)).map(\.text)
    }
    #expect(roundTrip(.vtt, "AT&T said <b> --> ok") == ["AT&T said <b> --> ok"])
    #expect(roundTrip(.srt, "AT&T said <b> --> ok") == ["AT&T said <b> --> ok"])
    // WebVTT escapes `&` too, so a literal entity in the text decodes exactly once. (SubRip leaves `&`
    // raw, so the same text cannot round-trip through .srt — the exporter's output is ambiguous there.)
    #expect(roundTrip(.vtt, "write &lt; for <") == ["write &lt; for <"])
}
