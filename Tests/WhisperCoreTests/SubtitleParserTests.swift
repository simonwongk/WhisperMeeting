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

// F491 — WebVTT carries `<`, `>` and `&` as character references (so did TranscriptExporter's own
// SRT until F743). Label stripping was anchored on a literal `>>`, so an escaped chevron used to
// slip past it whole.
@Test("Strips a speaker label whose chevrons arrive entity-escaped (no-diarization invariant, F491)")
func stripsEntityEscapedSpeakerLabels() {
    func text(_ cue: String) -> String? {
        SubtitleParser.parse("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n\(cue)").first?.text
    }
    #expect(text("&gt;&gt; JOHN: Good morning.") == "Good morning.")
    #expect(text("&gt;&gt; and then we shipped") == "and then we shipped")
}

// F743 reads a file's references as text unless it begins with the WEBVTT header. A link import
// adopts its caption by the .vtt name, not the header, and a caption converted to SubRip keeps
// WebVTT's references as text — so the escaped chevron must still be a speaker change there.
@Test("Strips an entity-escaped speaker label from any caption file, whatever its first line (no-diarization invariant, F743)")
func stripsEntityEscapedSpeakerLabelsInAnyFile() {
    // A .vtt with a blank line before its header, one with no header, and two SubRip files.
    #expect(SubtitleParser.parse("\nWEBVTT\n\n00:00:00.000 --> 00:00:02.000\n&gt;&gt; JOHN: we shipped\n").map(\.text) == ["we shipped"])
    #expect(SubtitleParser.parse("00:00:00.000 --> 00:00:02.000\n&gt;&gt; JOHN: we shipped\n").map(\.text) == ["we shipped"])
    #expect(SubtitleParser.parse("1\n00:00:00,000 --> 00:00:02,000\n&gt;&gt; JOHN: we shipped\n").map(\.text) == ["we shipped"])
    #expect(SubtitleParser.parse("1\n00:00:00,000 --> 00:00:02,000\n&gt;>&gt; and then we shipped\n").map(\.text) == ["and then we shipped"])
    // A reference that is not a leading chevron is still text in SubRip, as F743 reads it.
    #expect(SubtitleParser.parse("1\n00:00:00,000 --> 00:00:02,000\nsay &gt;&gt; twice\n").map(\.text) == ["say &gt;&gt; twice"])
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
    // WebVTT escapes `&` too, so a literal entity in the text decodes exactly once. SubRip has no
    // character references at all (F743): the exporter writes `<` with a word joiner after it, and
    // a literal `&lt;` comes back as the text it is.
    #expect(roundTrip(.vtt, "write &lt; for <") == ["write &lt; for <"])
    #expect(roundTrip(.srt, "write &lt; for <") == ["write &lt; for <"])
    #expect(roundTrip(.srt, "x<y>z and <i>not a tag</i>") == ["x<y>z and <i>not a tag</i>"])
}

@Test("A SubRip file's character references are text, as SubRip players show them; WebVTT's are decoded (F743)")
func subRipReferencesAreText() {
    let srt = "1\n00:00:00,000 --> 00:00:02,000\nR&amp;D said &lt;b&gt; <i>quietly</i>\n"
    #expect(SubtitleParser.parse(srt).map(\.text) == ["R&amp;D said &lt;b&gt; quietly"])
    let vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nR&amp;D said &lt;b&gt; <i>quietly</i>\n"
    #expect(SubtitleParser.parse(vtt).map(\.text) == ["R&D said <b> quietly"])
    // A byte-order mark before the header is still WebVTT.
    #expect(SubtitleParser.parse("\u{FEFF}" + vtt).map(\.text) == ["R&D said <b> quietly"])
}
