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
    /// The two formats below are the ONLY ones allowed to carry speaker labels, and they are
    /// deliberately absent from `standardFormats` (F220).
    case labeledText
    case labeledMarkdown

    /// The nine formats offered as ordinary exports: everything a transcript is normally needed as,
    /// and nothing that can carry a speaker label. Listed explicitly rather than derived from
    /// `allCases` minus a denylist, so adding a labeled format later cannot silently opt itself in.
    public static let standardFormats: [TranscriptExportFormat] = [
        .plainText, .timestampedText, .markdown, .srt, .vtt,
        .json, .chapterList, .chapteredMarkdown, .html
    ]

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
        case .labeledText: "Transcript with Speaker Labels (.txt)"
        case .labeledMarkdown: "Transcript with Speaker Labels (.md)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText, .timestampedText, .chapterList, .labeledText: "txt"
        case .markdown, .chapteredMarkdown, .labeledMarkdown: "md"
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
        case .srt, .vtt, .json, .chapteredMarkdown, .html, .labeledText, .labeledMarkdown: true
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
    /// The label a person typed for one anonymous cluster, keyed by cluster id, for this meeting
    /// only. Every entry here is treated as **user-assigned** and is marked as such in the output, so
    /// pass only names someone actually typed — a cluster with no entry renders the anonymous default
    /// (`Speaker 1`). Read by the two labeled formats and by nothing else (F220).
    public let speakerLabels: [Int: String]
    /// The display-only speaker overlay, one row per entry in `segments`. Never written back into a
    /// `TranscriptSegment`, never into `transcriptText`, and never read by a standard format.
    public let speakerRows: [SpeakerOverlayRow]

    public init(
        title: String,
        languageCode: String?,
        durationSeconds: TimeInterval,
        transcriptText: String,
        segments: [TranscriptSegment],
        markers: [RecordingMarker] = [],
        speakerLabels: [Int: String] = [:],
        speakerRows: [SpeakerOverlayRow] = []
    ) {
        self.title = title
        self.languageCode = languageCode
        self.durationSeconds = durationSeconds
        self.transcriptText = transcriptText
        self.segments = segments
        self.markers = markers
        self.speakerLabels = speakerLabels
        self.speakerRows = speakerRows
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
            return srt(foldUntimedSegments(effectiveSegments(request), durationSeconds: request.durationSeconds))
        case .vtt:
            return vtt(foldUntimedSegments(effectiveSegments(request), durationSeconds: request.durationSeconds))
        case .json:
            return json(request)
        case .chapterList:
            return TranscriptChapters.list(chapters(request))
        case .chapteredMarkdown:
            return TranscriptChapters.markdown(chapters(request))
        case .html:
            return html(request)
        case .labeledText:
            return labeled(request, markdown: false)
        case .labeledMarkdown:
            return labeled(request, markdown: true)
        }
    }

    private static func chapters(_ request: TranscriptExportRequest) -> [TranscriptChapter] {
        TranscriptChapters.chapters(
            markers: request.markers,
            segments: foldUntimedSegments(effectiveSegments(request), durationSeconds: request.durationSeconds),
            durationSeconds: request.durationSeconds
        )
    }

    /// Groups every UNTIMED segment (F263's designed state for a passage forced alignment could not
    /// place) into the neighbouring TIMED one, for the formats that need a start time to represent an
    /// item at all — an SRT/WebVTT cue, or chapter membership (`TranscriptChapters.assign` drops a
    /// nil-start segment outright). JSON and HTML do NOT call this: both already render a nil start as
    /// itself (a `null` field, a `<p>` with no timestamp anchor), so folding there would only throw
    /// away information those formats are able to keep (F473).
    ///
    /// An untimed segment folds into the segment before it, matching how a reader encounters it —
    /// immediately after whatever was just said. A run of untimed segments with nothing before them
    /// yet (the transcript OPENS with one) instead attaches to the first timed segment that follows,
    /// so nothing at the very start is silently dropped. If NOTHING in the transcript ever had a
    /// timestamp, there is nothing to fold into, so this falls back to the same single whole-duration
    /// segment the no-segments path above already produces for pure, untimed text.
    ///
    /// Folding text into a cue without widening the cue's WINDOW is a timing lie (AGENTS.md's F275
    /// lesson, applied here to export rather than capture): text folded in from AFTER a cue's own
    /// natural end could have been said any time up to the next cue's start, so the cue's displayed
    /// end must widen to that next start (or the recording's duration, if nothing timed follows) —
    /// otherwise the cue claims its folded words were said before they necessarily were. The mirror
    /// case is leading text folded into the FIRST cue: it could have been said any time from the very
    /// start of the recording, so that cue's START widens to 0 rather than keeping its own later,
    /// natural start.
    private static func foldUntimedSegments(
        _ segments: [TranscriptSegment],
        durationSeconds: TimeInterval
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        // Parallel to `result`: true for a cue that had TRAILING untimed text folded into it, so its
        // `end` still needs widening once the next cue's `start` (or the lack of one) is known.
        var needsEndWidened: [Bool] = []
        var pendingLeadingText: [String] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.start != nil else {
                guard !text.isEmpty else { continue }
                if result.isEmpty {
                    pendingLeadingText.append(text)
                } else {
                    let lastIndex = result.count - 1
                    result[lastIndex].text += "\n" + text
                    needsEndWidened[lastIndex] = true
                }
                continue
            }
            var timedSegment = segment
            if pendingLeadingText.isEmpty {
                timedSegment.text = text
            } else {
                timedSegment.text = (pendingLeadingText + [text]).joined(separator: "\n")
                pendingLeadingText = []
                // The leading text could have been said any time from the very start of the
                // recording up to this cue's own natural start — the window must cover that whole
                // span, not just the part after this cue's own speech began.
                timedSegment.start = 0
            }
            result.append(timedSegment)
            needsEndWidened.append(false)
        }
        guard !result.isEmpty else {
            let wholeText = pendingLeadingText.joined(separator: "\n")
            guard !wholeText.isEmpty else { return [] }
            return [TranscriptSegment(speaker: nil, start: 0, end: max(0, durationSeconds), text: wholeText)]
        }
        let cappedDuration = max(0, durationSeconds)
        for index in result.indices where needsEndWidened[index] {
            let nextStart = result.indices.contains(index + 1) ? result[index + 1].start : nil
            result[index].end = min(nextStart ?? cappedDuration, cappedDuration)
        }
        return result
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
            switch (line.start, segment.start) {
            case (nil, nil):
                // An untimed line matching an untimed segment (F473): F263 made a passage with no
                // timestamp a DESIGNED state (bare line, no drift to check), not a defect — treating
                // it as misaligned was what collapsed the whole export into one cue.
                return true
            case let (editedStart?, originalStart?):
                // The editable transcript displays whole seconds while Whisper retains subsecond cue
                // precision. Preserve that precision only when the visible whole-second timestamp was
                // not changed by the user.
                return Int(saturating: editedStart.rounded(.down)) == Int(saturating: originalStart.rounded(.down))
            default:
                // One side has a timestamp and the other does not — genuine drift (an edit added or
                // removed a line's timestamp), not F263's untimed-by-design case.
                return false
            }
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
        if let meta = metaLine(request) {
            lines.append(meta)
            lines.append("")
        }
        lines.append(request.transcriptText)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The italic `_Duration: … · Language: …_` line, shared by the Markdown exports. `nil` when
    /// there is nothing to say, so neither export emits an empty emphasis pair.
    private static func metaLine(_ request: TranscriptExportRequest) -> String? {
        var meta: [String] = []
        if request.durationSeconds > 0 {
            meta.append("Duration: \(TranscriptFormatter.clock(request.durationSeconds))")
        }
        if let language = request.languageCode, !language.isEmpty {
            meta.append("Language: \(language.uppercased())")
        }
        guard !meta.isEmpty else { return nil }
        return "_\(meta.joined(separator: " · "))_"
    }

    // MARK: - Labeled exports (F220)

    /// The anonymous name for one voice cluster, in the single spelling the labeled exports and the
    /// review UI both use. Cluster ids are dense and zero-based, and are local to one meeting:
    /// `Speaker 1` here is not a claim that the same voice appears in any other recording.
    public static func anonymousSpeakerName(clusterID: Int) -> String {
        "Speaker \(clusterID + 1)"
    }

    /// What a labeled export says about itself, once, at the top.
    ///
    /// Every claim is deliberately weaker than "who spoke": voices are grouped, not people, and a
    /// name is the reader's own label. The words "recognized", "identified" and "verified" never
    /// appear — not even negated, because a sentence promising the app "did not identify anyone"
    /// still prints the word, and a test pins its absence (`AccessibilityPhrase.swift:4`).
    private static let speakerLabelNotice = """
    These speaker labels were inferred on this Mac by local analysis of the recording. They group \
    similar-sounding audio inside this one meeting: they are anonymous, they are never matched to a \
    person or to any other recording, and they can be wrong — voices that sound alike are sometimes \
    merged into a single label. A name below was typed by you for this meeting and is marked \
    "(your label)". The recording remains the source of truth.
    """

    /// The only two formats that may carry the speaker overlay. Every other format renders from the
    /// same request and must come out label-free — `standardExportsNeverCarrySpeakerLabels` pins
    /// that, and it is why `speakerLabels`/`speakerRows` are read here and nowhere else.
    private static func labeled(_ request: TranscriptExportRequest, markdown: Bool) -> String {
        let segments = effectiveSegments(request)
        let overlay = trustedOverlay(request, renderedCount: segments.count)

        var blocks: [String] = []
        if markdown {
            blocks.append("# \(request.title)")
            if let meta = metaLine(request) { blocks.append(meta) }
        }
        // No usable overlay means nothing to explain: the file is then the ordinary transcript, with
        // no notice promising labels it does not contain.
        if !overlay.isEmpty {
            blocks.append(markdown ? "> \(speakerLabelNotice)" : speakerLabelNotice)
        }

        var body: [String] = []
        body.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let prefix = overlay[index].map {
                speakerPrefix($0, request.speakerLabels, markdown: markdown)
            } ?? ""
            guard let start = segment.start else {
                body.append(prefix + text)
                continue
            }
            let stamp = TranscriptFormatter.timestamp(start)
            body.append(markdown ? "`\(stamp)` \(prefix)\(text)" : "\(stamp)  \(prefix)\(text)")
        }

        // Markdown wants a blank line between paragraphs; plain text is one line per segment in the
        // exact shape `TranscriptFormatter.timestamped` produces, so a labeled export with no overlay
        // is the ordinary timestamped transcript rather than a second, subtly different rendering.
        if !body.isEmpty {
            blocks.append(body.joined(separator: markdown ? "\n\n" : "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The visible label for one row, already punctuated. `.unlabeled` never reaches here because
    /// `trustedOverlay` drops it: a row the analysis could not attribute renders with no prefix at
    /// all, never an empty placeholder that would read as a fourth kind of speaker.
    private static func speakerPrefix(
        _ label: SpeakerOverlayLabel,
        _ speakerLabels: [Int: String],
        markdown: Bool
    ) -> String {
        func plain(_ name: String) -> String { markdown ? "**\(name):** " : "\(name): " }
        switch label {
        case let .speaker(clusterID):
            guard let alias = typedName(speakerLabels[clusterID]) else {
                return plain(anonymousSpeakerName(clusterID: clusterID))
            }
            // The marker travels with the name, not only with the notice at the top, so a single line
            // quoted out of this file still says the name is a label someone typed.
            return markdown ? "**\(alias)** (your label): " : "\(alias) (your label): "
        case .overlapping:
            return plain(SpeakerOverlay.overlappingName)
        case .uncertain:
            return plain(SpeakerOverlay.uncertainName)
        case .unlabeled:
            return ""
        }
    }

    /// A person-typed alias, folded onto one line. `DiarizationArtifactV1.clampedAlias` bounds the
    /// length and trims the ends but keeps interior newlines, and one of those would split a
    /// transcript line in two; an empty or blank alias means the label was cleared.
    private static func typedName(_ alias: String?) -> String? {
        SpeakerOverlay.typedAlias(alias)
    }

    /// The overlay keyed by segment index — but only while it still describes the lines about to be
    /// rendered. `speakerRows` is computed against `request.segments`, and `effectiveSegments` may
    /// re-split an edited transcript into a different list, at which point row 3 is no longer about
    /// line 3. Rather than move a name onto someone else's words, drop every label: the file then
    /// renders as the plain transcript, which is wrong about nothing.
    private static func trustedOverlay(
        _ request: TranscriptExportRequest,
        renderedCount: Int
    ) -> [Int: SpeakerOverlayLabel] {
        let rows = request.speakerRows
        guard !rows.isEmpty, rows.count == request.segments.count, renderedCount == rows.count else {
            return [:]
        }
        var overlay: [Int: SpeakerOverlayLabel] = [:]
        for row in rows where row.label != .unlabeled {
            guard row.segmentIndex >= 0, row.segmentIndex < renderedCount else { return [:] }
            overlay[row.segmentIndex] = row.label
        }
        return overlay
    }

    private static func srt(_ segments: [TranscriptSegment]) -> String {
        var blocks: [String] = []
        var index = 1
        for segment in segments {
            let text = collapseBlankLines(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
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
            let text = collapseBlankLines(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty, let start = segment.start else { continue }
            let end = segment.end ?? start
            lines.append("\(subtitleTimestamp(start, millisecondSeparator: ".")) --> \(subtitleTimestamp(end, millisecondSeparator: "."))")
            lines.append(escapeCueText(text, escapeAmpersand: true))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A blank line ends a cue in both SRT and WebVTT (F508 Part 2). The no-segments export path
    /// (`effectiveSegments`, above) can hand a single segment the WHOLE untimed transcript verbatim,
    /// interior blank lines and all — a multi-paragraph transcript with no timestamps to split it by
    /// — so without this, the first paragraph becomes a complete, validly-timed cue and every
    /// paragraph after the first blank line is orphaned text with no cue header at all. Collapsing
    /// keeps the segment as one intact cue regardless of which path produced its text.
    private static func collapseBlankLines(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
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
    ///
    /// F508, the F287 `%d` defect's unfixed sibling: `TranscriptFormatter.clock`/`timestamp` moved
    /// to `%ld` because `String(format:)` reads `%d` as 32 bits off the varargs list, so an hour
    /// count past `Int32.max` wraps to a negative number — this formatter kept `%02d` and was never
    /// touched. Reachable the same way: a `duration` or segment `end` that decodes to an implausible
    /// finite value (1e30, the AGENTS.md decodable-corrupt case) is exported as SRT/WebVTT with no
    /// segments backing it, and `effectiveSegments` uses that value directly as the lone cue's end.
    ///
    /// The upper clamp mirrors `TranscriptFormatter.wholeSeconds`'s own 1e15-second ceiling (F287):
    /// applied in Double space, before any Int conversion, to the same ~31-million-year bound. It is
    /// not what stops the overflow by itself — 1e15 seconds is already ~2.78×10^11 hours, itself far
    /// past `Int32.max` — so `%ld` is still the fix; the clamp only keeps the value a Double can
    /// represent exactly and keeps `* 1000` for milliseconds from ever needing to saturate.
    static func subtitleTimestamp(_ seconds: Double, millisecondSeparator: String) -> String {
        let clamped = max(0, min(1_000_000_000_000_000, seconds))
        let totalMilliseconds = Int(saturating: (clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02ld:%02d:%02d%@%03d", hours, minutes, secs, millisecondSeparator, milliseconds)
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
