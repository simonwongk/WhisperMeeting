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
    let segments = decoded?["segments"] as? [[String: Any]]
    #expect(segments?.count == 2)
    #expect(segments?.first?["text"] as? String == "Hello everyone.")
}

@Test("Plain-text export strips timestamps from meetings past 100 minutes")
func stripsThreeDigitMinuteTimestamps() {
    let request = TranscriptExportRequest(
        title: "Long Session",
        languageCode: "en",
        durationSeconds: 6_100,
        transcriptText: "99:59  Almost there.\n100:05  Wrap up.",
        segments: []
    )
    #expect(TranscriptExporter.render(.plainText, request) == "Almost there.\nWrap up.")
}

@Test("Subtitle timestamps format hours, minutes, seconds, and milliseconds")
func formatsSubtitleTimestamps() {
    #expect(TranscriptExporter.subtitleTimestamp(3661.5, millisecondSeparator: ",") == "01:01:01,500")
    #expect(TranscriptExporter.subtitleTimestamp(0, millisecondSeparator: ".") == "00:00:00.000")
}
