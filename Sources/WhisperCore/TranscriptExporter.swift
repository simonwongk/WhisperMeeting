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

    public var displayName: String {
        switch self {
        case .plainText: "Plain Text (.txt)"
        case .timestampedText: "Timestamped Text (.txt)"
        case .markdown: "Markdown (.md)"
        case .srt: "Subtitles — SubRip (.srt)"
        case .vtt: "Subtitles — WebVTT (.vtt)"
        case .json: "JSON (.json)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText, .timestampedText: "txt"
        case .markdown: "md"
        case .srt: "srt"
        case .vtt: "vtt"
        case .json: "json"
        }
    }

    /// Formats built from timestamped `segments` do not reflect freeform transcript edits; text and
    /// Markdown formats use the (possibly edited) transcript text as shown to the user.
    public var usesSegments: Bool {
        switch self {
        case .srt, .vtt, .json: true
        case .plainText, .timestampedText, .markdown: false
        }
    }
}

public struct TranscriptExportRequest: Sendable {
    public let title: String
    public let languageCode: String?
    public let durationSeconds: TimeInterval
    public let transcriptText: String
    public let segments: [TranscriptSegment]

    public init(
        title: String,
        languageCode: String?,
        durationSeconds: TimeInterval,
        transcriptText: String,
        segments: [TranscriptSegment]
    ) {
        self.title = title
        self.languageCode = languageCode
        self.durationSeconds = durationSeconds
        self.transcriptText = transcriptText
        self.segments = segments
    }
}

public enum TranscriptExporter {
    public static func render(
        _ format: TranscriptExportFormat,
        _ request: TranscriptExportRequest
    ) -> String {
        switch format {
        case .plainText:
            return TranscriptFormatter.stripTimestamps(request.transcriptText)
        case .timestampedText:
            return request.transcriptText
        case .markdown:
            return markdown(request)
        case .srt:
            return srt(request.segments)
        case .vtt:
            return vtt(request.segments)
        case .json:
            return json(request)
        }
    }

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
            \(text)
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
            lines.append(text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func json(_ request: TranscriptExportRequest) -> String {
        let payload = ExportPayload(
            title: request.title,
            language: request.languageCode,
            durationSeconds: request.durationSeconds,
            segments: request.segments.map {
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
    let segments: [Segment]
}
