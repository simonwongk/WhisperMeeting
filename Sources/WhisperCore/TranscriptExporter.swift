import Foundation

/// Formats a finished transcript into the file formats a meeting transcript is commonly needed in.
/// Pure and framework-free so it can be unit-tested; the GUI only chooses a format and writes the
/// returned string to disk.
public enum TranscriptExportFormat: String, CaseIterable, Sendable, Hashable {
    case plainText
    case timestampedText
    case markdown
    case srt
    case vtt
    case json
    case chapterList
    case chapteredMarkdown
    case html

    public var displayName: String {
        switch self {
        case .plainText: "Plain Text (.txt)"
        case .timestampedText: "Timestamped Text (.txt)"
        case .markdown: "Markdown (.md)"
        case .srt: "Subtitles — SubRip (.srt)"
        case .vtt: "Subtitles — WebVTT (.vtt)"
        case .json: "JSON (.json)"
        case .chapterList: "Chapter List (.txt)"
        case .chapteredMarkdown: "Chaptered Transcript (.md)"
        case .html: "Web Page (.html)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText, .timestampedText, .chapterList: "txt"
        case .markdown, .chapteredMarkdown: "md"
        case .srt: "srt"
        case .vtt: "vtt"
        case .json: "json"
        case .html: "html"
        }
    }

    /// Formats that require timed cues. Their cue text and any visibly edited timestamps are derived
    /// from the current transcript; original subsecond timings are retained only when lines still
    /// align with the displayed Whisper timestamps.
    public var usesSegments: Bool {
        switch self {
        case .srt, .vtt, .json, .chapteredMarkdown, .html: true
        case .plainText, .timestampedText, .markdown, .chapterList: false
        }
    }
}

public struct TranscriptExportRequest: Sendable {
    public let title: String
    public let languageCode: String?
    public let durationSeconds: TimeInterval
    public let transcriptText: String
    public let segments: [TranscriptSegment]
    public let markers: [RecordingMarker]

    public init(
        title: String,
        languageCode: String?,
        durationSeconds: TimeInterval,
        transcriptText: String,
        segments: [TranscriptSegment],
        markers: [RecordingMarker] = []
    ) {
        self.title = title
        self.languageCode = languageCode
        self.durationSeconds = durationSeconds
        self.transcriptText = transcriptText
        self.segments = segments
        self.markers = markers
    }
}

public enum TranscriptExporter {
    private struct TranscriptLine {
        let start: TimeInterval?
        let text: String
    }

    public static func render(
        _ format: TranscriptExportFormat,
        _ request: TranscriptExportRequest
    ) -> String {
        switch format {
        case .plainText:
            // Only strip leading timestamps when timed segments actually back the transcript.
            // Without them a leading clock-like token ("3:00 PM") is prose, not a timestamp (F42).
            return request.segments.isEmpty
                ? request.transcriptText
                : TranscriptFormatter.stripTimestamps(request.transcriptText)
        case .timestampedText:
            return request.transcriptText
        case .markdown:
            return markdown(request)
        case .srt:
            return srt(effectiveSegments(request))
        case .vtt:
            return vtt(effectiveSegments(request))
        case .json:
            return json(request)
        case .chapterList:
            return TranscriptChapters.list(chapters(request))
        case .chapteredMarkdown:
            return TranscriptChapters.markdown(chapters(request))
        case .html:
            return html(request)
        }
    }

    private static func chapters(_ request: TranscriptExportRequest) -> [TranscriptChapter] {
        TranscriptChapters.chapters(
            markers: request.markers,
            segments: effectiveSegments(request),
            durationSeconds: request.durationSeconds
        )
    }

    /// The editable transcript is the user-facing source of truth. When its non-empty lines still
    /// align one-for-one with Whisper's segments, preserve the precise original timings while
    /// replacing segment text with the current edited text.
    private static func effectiveSegments(_ request: TranscriptExportRequest) -> [TranscriptSegment] {
        // Without timed segments backing the transcript, a leading clock-like token is prose, not a
        // cue time — do not parse or strip it. Emit one cue spanning the whole duration (F42).
        guard !request.segments.isEmpty else {
            let text = request.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptSegment(
                speaker: nil,
                start: 0,
                end: max(0, request.durationSeconds),
                text: text
            )]
        }
        let editedLines = transcriptLines(request.transcriptText)
        if linesStillAlignWithOriginalTimings(editedLines, request.segments) {
            return zip(request.segments, editedLines).map { segment, line in
                TranscriptSegment(
                    speaker: segment.speaker,
                    start: segment.start,
                    end: segment.end,
                    text: line.text
                )
            }
        }
        if !editedLines.isEmpty, editedLines.allSatisfy({ $0.start != nil }) {
            return editedLines.enumerated().map { index, line in
                let start = line.start ?? 0
                let nextStart = editedLines.indices.contains(index + 1)
                    ? editedLines[index + 1].start
                    : nil
                return TranscriptSegment(
                    speaker: nil,
                    start: start,
                    end: max(start, nextStart ?? request.durationSeconds),
                    text: line.text
                )
            }
        }
        let text = editedLines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            speaker: nil,
            start: 0,
            end: max(0, request.durationSeconds),
            text: text
        )]
    }

    private static func linesStillAlignWithOriginalTimings(
        _ lines: [TranscriptLine],
        _ segments: [TranscriptSegment]
    ) -> Bool {
        guard !lines.isEmpty, lines.count == segments.count else { return false }
        return zip(lines, segments).allSatisfy { line, segment in
            guard let editedStart = line.start, let originalStart = segment.start else {
                return false
            }
            // The editable transcript displays whole seconds while Whisper retains subsecond cue
            // precision. Preserve that precision only when the visible whole-second timestamp was
            // not changed by the user.
            return Int(editedStart.rounded(.down)) == Int(originalStart.rounded(.down))
        }
    }

    private static func transcriptLines(_ text: String) -> [TranscriptLine] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = timestampedLineRegex.firstMatch(in: line, range: range),
                  let clockRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else {
                return TranscriptLine(start: nil, text: line)
            }
            let clock = line[clockRange].split(separator: ":").compactMap { Double($0) }
            guard clock.count == 2 || clock.count == 3 else {
                return TranscriptLine(start: nil, text: line)
            }
            let start = clock.reduce(0) { $0 * 60 + $1 }
            return TranscriptLine(
                start: start,
                text: line[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static let timestampedLineRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:\d{1,3}:)?\d{1,3}:\d{2})\s+(.+?)\s*$"#
    )

    private static func markdown(_ request: TranscriptExportRequest) -> String {
        var lines = ["# \(request.title)", ""]
        var meta: [String] = []
        if request.durationSeconds > 0 {
            meta.append("Duration: \(TranscriptFormatter.clock(request.durationSeconds))")
        }
        if let language = request.languageCode, !language.isEmpty {
            meta.append("Language: \(language.uppercased())")
        }
        if !meta.isEmpty {
            lines.append("_\(meta.joined(separator: " · "))_")
            lines.append("")
        }
        lines.append(request.transcriptText)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func srt(_ segments: [TranscriptSegment]) -> String {
        var blocks: [String] = []
        var index = 1
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = segment.start else { continue }
            let end = segment.end ?? start
            blocks.append("""
            \(index)
            \(subtitleTimestamp(start, millisecondSeparator: ",")) --> \(subtitleTimestamp(end, millisecondSeparator: ","))
            \(escapeCueText(text, escapeAmpersand: false))
            """)
            index += 1
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    private static func vtt(_ segments: [TranscriptSegment]) -> String {
        var lines = ["WEBVTT", ""]
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = segment.start else { continue }
            let end = segment.end ?? start
            lines.append("\(subtitleTimestamp(start, millisecondSeparator: ".")) --> \(subtitleTimestamp(end, millisecondSeparator: "."))")
            lines.append(escapeCueText(text, escapeAmpersand: true))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A standalone, offline HTML document: inline `<style>` only (no external CSS/fonts/images),
    /// HTML-escaped text, per-segment MM:SS anchors, and an optional markers table of contents. The
    /// no-external-URL guarantee is what keeps it local (F61).
    private static func html(_ request: TranscriptExportRequest) -> String {
        let title = htmlEscape(request.title)
        var parts: [String] = ["<h1>\(title)</h1>"]

        var meta: [String] = []
        if request.durationSeconds > 0 { meta.append(htmlEscape(TranscriptFormatter.clock(request.durationSeconds))) }
        if let language = request.languageCode, !language.isEmpty { meta.append(htmlEscape(language.uppercased())) }
        if !meta.isEmpty { parts.append("<p class=\"meta\">\(meta.joined(separator: " · "))</p>") }

        let orderedMarkers = request.markers.sorted { $0.offset < $1.offset }
        if !orderedMarkers.isEmpty {
            var toc = ["<nav class=\"toc\"><h2>Markers</h2><ul>"]
            for (index, marker) in orderedMarkers.enumerated() {
                let label = htmlEscape(RecordingMarkers.displayLabel(for: marker, at: index + 1))
                toc.append("<li><span class=\"ts\">\(TranscriptFormatter.timestamp(marker.offset))</span> \(label)</li>")
            }
            toc.append("</ul></nav>")
            parts.append(toc.joined(separator: "\n"))
        }

        let segments = effectiveSegments(request)
        parts.append("<section class=\"transcript\">")
        if segments.isEmpty {
            parts.append("<p>\(htmlEscape(request.transcriptText))</p>")
        } else {
            for segment in segments {
                let text = htmlEscape(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let start = segment.start {
                    let stamp = TranscriptFormatter.timestamp(start)
                    parts.append("<p id=\"seg-\(Int(start))\"><span class=\"ts\">\(stamp)</span> \(text)</p>")
                } else {
                    parts.append("<p>\(text)</p>")
                }
            }
        }
        parts.append("</section>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <style>
        body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; line-height: 1.55; color: #1a1a1a; }
        h1 { font-size: 1.6rem; }
        .meta { color: #666; }
        .ts { color: #888; font-variant-numeric: tabular-nums; margin-right: .5rem; }
        .toc { border: 1px solid #ddd; border-radius: 8px; padding: .5rem 1rem; }
        .transcript p { margin: .4rem 0; }
        </style>
        </head>
        <body>
        \(parts.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped
    }

    private static func json(_ request: TranscriptExportRequest) -> String {
        let segments = effectiveSegments(request)
        let payload = ExportPayload(
            title: request.title,
            language: request.languageCode,
            durationSeconds: request.durationSeconds,
            transcriptText: request.transcriptText,
            segments: segments.map {
                ExportPayload.Segment(start: $0.start, end: $0.end, text: $0.text)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Escape characters that would make subtitle cue text invalid or mis-render. WebVTT decodes
    /// entities and forbids a literal `-->` in a cue, so it needs `&`, `<`, `>` escaped (escaping `>`
    /// also neutralizes any `-->`). SubRip does not decode `&`, so only `<`/`>` are escaped there to
    /// avoid a stray `<tag>` being interpreted (F44). Order matters: `&` first.
    private static func escapeCueText(_ text: String, escapeAmpersand: Bool) -> String {
        var escaped = text
        if escapeAmpersand {
            escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        }
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        return escaped
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (WebVTT).
    static func subtitleTimestamp(_ seconds: Double, millisecondSeparator: String) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, millisecondSeparator, milliseconds)
    }
}

private struct ExportPayload: Codable {
    struct Segment: Codable {
        let start: Double?
        let end: Double?
        let text: String
    }

    let title: String
    let language: String?
    let durationSeconds: TimeInterval
    let transcriptText: String
    let segments: [Segment]
}
