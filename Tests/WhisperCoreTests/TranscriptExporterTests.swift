import Foundation
import Testing
@testable import WhisperCore

private func sampleRequest() -> TranscriptExportRequest {
    TranscriptExportRequest(
        title: "Weekly Sync",
        languageCode: "en",
        durationSeconds: 65,
        transcriptText: "00:00  Hello everyone.\n00:03  Let's begin.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0.25, end: 2.5, text: "Hello everyone."),
            TranscriptSegment(speaker: nil, start: 3.0, end: 5.0, text: "Let's begin."),
        ]
    )
}

@Test("SRT export numbers cues and uses comma millisecond separators")
func exportsSubRip() {
    let srt = TranscriptExporter.render(.srt, sampleRequest())
    #expect(srt.contains("1\n00:00:00,250 --> 00:00:02,500\nHello everyone."))
    #expect(srt.contains("2\n00:00:03,000 --> 00:00:05,000\nLet's begin."))
}

@Test("WebVTT export starts with the WEBVTT header and uses dot separators")
func exportsWebVTT() {
    let vtt = TranscriptExporter.render(.vtt, sampleRequest())
    #expect(vtt.hasPrefix("WEBVTT\n"))
    #expect(vtt.contains("00:00:00.250 --> 00:00:02.500\nHello everyone."))
}

@Test("Export does not strip a leading clock-like token from a non-timestamped transcript")
func preservesLeadingClockOnUntimestampedTranscript() {
    let request = TranscriptExportRequest(
        title: "t",
        languageCode: nil,
        durationSeconds: 60,
        transcriptText: "3:00 PM kickoff",
        segments: []
    )

    // Plain text keeps the prose token verbatim.
    #expect(TranscriptExporter.render(.plainText, request) == "3:00 PM kickoff")

    // SRT keeps "3:00" in the cue text and does not mis-time the cue to 00:03:00.
    let srt = TranscriptExporter.render(.srt, request)
    #expect(srt.contains("3:00 PM kickoff"))
    #expect(srt.contains("00:00:00,000 -->"))
}

@Test("WebVTT and SubRip escape special characters in cue text")
func escapesSubtitleCueText() {
    let request = TranscriptExportRequest(
        title: "t",
        languageCode: nil,
        durationSeconds: 1,
        transcriptText: "R&D <plan> --> done",
        segments: []
    )

    let vtt = TranscriptExporter.render(.vtt, request)
    #expect(vtt.contains("R&amp;D &lt;plan&gt;"))
    // The only "-->" is the cue-time separator; the escaped payload carries "--&gt;" instead.
    #expect(vtt.components(separatedBy: "-->").count - 1 == 1)

    let srt = TranscriptExporter.render(.srt, request)
    #expect(srt.contains("R&D &lt;plan&gt;")) // SRT escapes < >, leaves & literal
    #expect(srt.components(separatedBy: "-->").count - 1 == 1)
}

@Test("Plain-text export strips the leading timestamps from each line")
func exportsPlainText() {
    let text = TranscriptExporter.render(.plainText, sampleRequest())
    #expect(text == "Hello everyone.\nLet's begin.")
}

@Test("Markdown export includes a title heading and the transcript body")
func exportsMarkdown() {
    let markdown = TranscriptExporter.render(.markdown, sampleRequest())
    #expect(markdown.hasPrefix("# Weekly Sync\n"))
    #expect(markdown.contains("Duration: 1:05"))
    #expect(markdown.contains("00:00  Hello everyone."))
}

@Test("JSON export is valid and preserves segment timings")
func exportsJSON() throws {
    let json = TranscriptExporter.render(.json, sampleRequest())
    let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect(decoded?["title"] as? String == "Weekly Sync")
    #expect(decoded?["transcriptText"] as? String == "00:00  Hello everyone.\n00:03  Let's begin.")
    let segments = decoded?["segments"] as? [[String: Any]]
    #expect(segments?.count == 2)
    #expect(segments?.first?["text"] as? String == "Hello everyone.")
}

@Test("Plain-text export strips timestamps from meetings past 100 minutes")
func stripsThreeDigitMinuteTimestamps() {
    // A genuinely timestamped transcript is backed by timed segments (F42): empty segments mark a
    // verbatim, non-timestamped transcript, whose leading tokens must be preserved.
    let request = TranscriptExportRequest(
        title: "Long Session",
        languageCode: "en",
        durationSeconds: 6_100,
        transcriptText: "99:59  Almost there.\n100:05  Wrap up.",
        segments: [
            TranscriptSegment(speaker: nil, start: 5_999, end: 6_005, text: "Almost there."),
            TranscriptSegment(speaker: nil, start: 6_005, end: 6_100, text: "Wrap up."),
        ]
    )
    #expect(TranscriptExporter.render(.plainText, request) == "Almost there.\nWrap up.")
}

@Test("Subtitle timestamps format hours, minutes, seconds, and milliseconds")
func formatsSubtitleTimestamps() {
    #expect(TranscriptExporter.subtitleTimestamp(3661.5, millisecondSeparator: ",") == "01:01:01,500")
    #expect(TranscriptExporter.subtitleTimestamp(0, millisecondSeparator: ".") == "00:00:00.000")
}

@Test("Subtitle exports use the edited transcript text while preserving segment timing")
func exportsEditedTranscriptText() {
    let request = TranscriptExportRequest(
        title: "Edited",
        languageCode: "en",
        durationSeconds: 10,
        transcriptText: "00:00  Corrected opening.\n00:03  Corrected ending.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0.25, end: 2.5, text: "Old opening."),
            TranscriptSegment(speaker: nil, start: 3, end: 5, text: "Old ending."),
        ]
    )

    let srt = TranscriptExporter.render(.srt, request)

    #expect(srt.contains("00:00:00,250 --> 00:00:02,500\nCorrected opening."))
    #expect(srt.contains("00:00:03,000 --> 00:00:05,000\nCorrected ending."))
    #expect(!srt.contains("Old opening."))
}

@Test("Text-only transcripts still produce a complete subtitle export")
func exportsTextOnlyTranscriptAsSubtitle() {
    let request = TranscriptExportRequest(
        title: "Text only",
        languageCode: "zh",
        durationSeconds: 12,
        transcriptText: "这是完整的文字记录。",
        segments: []
    )

    let srt = TranscriptExporter.render(.srt, request)

    #expect(srt.contains("00:00:00,000 --> 00:00:12,000"))
    #expect(srt.contains("这是完整的文字记录。"))
}

@Test("Deleting transcript lines never resurrects stale segment text in exports")
func exportsChangedTranscriptStructure() {
    let request = TranscriptExportRequest(
        title: "Restructured",
        languageCode: "en",
        durationSeconds: 10,
        transcriptText: "00:03  Only this corrected line remains.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 2, text: "Deleted old line."),
            TranscriptSegment(speaker: nil, start: 3, end: 5, text: "Old wording."),
        ]
    )

    let vtt = TranscriptExporter.render(.vtt, request)

    #expect(vtt.contains("00:00:03.000 --> 00:00:10.000"))
    #expect(vtt.contains("Only this corrected line remains."))
    #expect(!vtt.contains("Deleted old line."))
    #expect(!vtt.contains("Old wording."))
}

@Test("Changing visible timestamps replaces stale Whisper timings even when line counts match")
func exportsEditedTranscriptTimestamps() {
    let request = TranscriptExportRequest(
        title: "Retimed",
        languageCode: "en",
        durationSeconds: 20,
        transcriptText: "00:05  Moved opening.\n00:12  Moved ending.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0.25, end: 2.5, text: "Old opening."),
            TranscriptSegment(speaker: nil, start: 3, end: 5, text: "Old ending."),
        ]
    )

    let srt = TranscriptExporter.render(.srt, request)

    #expect(srt.contains("00:00:05,000 --> 00:00:12,000\nMoved opening."))
    #expect(srt.contains("00:00:12,000 --> 00:00:20,000\nMoved ending."))
    #expect(!srt.contains("00:00:00,250"))
}

@Test("HTML export is self-contained, escaped, and offline")
func exportsSelfContainedHTML() {
    let request = TranscriptExportRequest(
        title: "R&D <review>",
        languageCode: "en",
        durationSeconds: 125,
        // Whole-second timestamps aligned with the segments so original timings are preserved.
        transcriptText: "00:00  Hello & welcome <script>\n01:05  Done.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 3, text: "Hello & welcome <script>"),
            TranscriptSegment(speaker: nil, start: 65, end: 70, text: "Done."),
        ]
    )

    let html = TranscriptExporter.render(.html, request)

    // Escaping (title + body).
    #expect(html.contains("R&amp;D &lt;review&gt;"))
    #expect(html.contains("Hello &amp; welcome &lt;script&gt;"))
    #expect(!html.contains("<script>")) // never raw

    // Exactly one <html and one <style>.
    #expect(html.components(separatedBy: "<html").count - 1 == 1)
    #expect(html.components(separatedBy: "<style").count - 1 == 1)

    // Offline: no external URLs anywhere.
    #expect(!html.contains("http://"))
    #expect(!html.contains("https://"))

    // Every segment timestamp appears.
    #expect(html.contains("00:00"))
    #expect(html.contains("01:05")) // 65s

    // An empty transcript still yields a valid minimal document.
    let empty = TranscriptExporter.render(.html, TranscriptExportRequest(
        title: "t", languageCode: nil, durationSeconds: 0, transcriptText: "", segments: []
    ))
    #expect(empty.contains("<html"))
    #expect(empty.contains("</html>"))
}

// MARK: - F508 (the F287 `%d` defect's unfixed sibling)

@Test("A clamped duration still formats as a non-negative SRT/VTT timestamp, not one wrapped negative by a 32-bit %d (F508)")
func subtitleTimestampClampsAnAbsurdDuration() {
    let text = TranscriptExporter.subtitleTimestamp(1e30, millisecondSeparator: ",")
    #expect(!text.contains("-"))

    // The clamp matches `TranscriptFormatter.wholeSeconds`'s own 1e15-second ceiling (F287). Capped
    // hours land at 1e15 / 3600 — already past `Int32.max` — so pinning the exact string is what
    // proves `%ld` (not the clamp alone) is doing the work: the clamp does not by itself bring the
    // hour count under a 32-bit format specifier's range.
    let cappedSeconds = 1_000_000_000_000_000
    let hours = cappedSeconds / 3600
    let minutes = (cappedSeconds / 60) % 60
    let secs = cappedSeconds % 60
    #expect(hours > Int(Int32.max))
    #expect(text == String(format: "%02ld:%02d:%02d,000", hours, minutes, secs))
}

@Test("SRT/VTT export of a no-segments transcript with an implausible duration reads as non-negative (F508 Part 1)")
func subtitleExportOfImplausibleDurationIsNonNegative() {
    // The AGENTS.md decodable-corrupt shape: a duration this large decodes cleanly (MeetingRecord.
    // duration is a plain Double) and, with no segments, `effectiveSegments` uses it directly as the
    // lone cue's end.
    let request = TranscriptExportRequest(
        title: "Corrupt duration", languageCode: "en", durationSeconds: 1e30,
        transcriptText: "Just one line.", segments: []
    )
    // The cue arrow itself ("-->") is made of hyphens, so strip it before checking for a stray
    // minus sign — otherwise every valid cue "fails" this check regardless of the timestamps.
    let srt = TranscriptExporter.render(.srt, request).replacingOccurrences(of: "-->", with: "to")
    #expect(!srt.contains("-"))
    let vtt = TranscriptExporter.render(.vtt, request).replacingOccurrences(of: "-->", with: "to")
    #expect(!vtt.contains("-"))
}

@Test("An untimed multi-paragraph transcript exports as one intact SRT/VTT cue, not one an interior blank line breaks (F508 Part 2)")
func subtitleExportCollapsesInteriorBlankLines() {
    let request = TranscriptExportRequest(
        title: "Untimed multi-paragraph", languageCode: "en", durationSeconds: 30,
        transcriptText: "First paragraph.\n\nSecond paragraph.", segments: []
    )

    let srt = TranscriptExporter.render(.srt, request)
    // Exactly one cue: index "1", one arrow line, and the two paragraphs joined with no blank line
    // between them — a blank line ends an SRT cue, orphaning whatever follows it as an invalid block.
    #expect(srt == "1\n00:00:00,000 --> 00:00:30,000\nFirst paragraph.\nSecond paragraph.\n")

    let vtt = TranscriptExporter.render(.vtt, request)
    #expect(vtt.contains("First paragraph.\nSecond paragraph."))
    #expect(!vtt.contains("First paragraph.\n\nSecond paragraph."))
}
