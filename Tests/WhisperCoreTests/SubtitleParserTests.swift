import Foundation
import Testing
@testable import WhisperCore

// F183 — captions → segments. Because the adopt action writes a caption span into the transcript, the
// parser must strip speaker labels (no-diarization invariant) and collapse rolling-caption duplicates.

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
