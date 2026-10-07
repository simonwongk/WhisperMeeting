import Foundation

/// The transcript as the user left it, read back as lines (F455).
///
/// A hand edit (`MeetingStore.editTranscript`) rewrites `transcriptText` and never touches the
/// stored segments, so anything that reads the segments after an edit reads what the user removed
/// or corrected. The exporter's SRT/VTT/labeled renderings already rebuilt their cues from the
/// edited lines; Ask Meetings and the F177 action-item quotes did not, and kept citing a sentence
/// the user had deleted. Both now read the same lines, parsed here, so the line rules — what counts
/// as a timestamp, when the original subsecond timings still apply — exist once.
public enum EditedTranscript {
    /// One non-empty line of the transcript text, with its `MM:SS` prefix parsed off when it has one.
    struct Line: Equatable {
        let start: TimeInterval?
        let text: String
    }

    /// The segments a reader of the transcript should use: the stored segments while the text is
    /// still their rendering, otherwise `segments(transcriptText:original:)`.
    ///
    /// A cleared transcript is edited to nothing (F837), so it reads as no lines at all — not, as it
    /// did until then, as every line the user cleared.
    public static func effectiveSegments(
        transcriptText: String,
        segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard TranscriptFormatter.isEdited(transcriptText: transcriptText, segments: segments) else {
            return segments
        }
        return self.segments(transcriptText: transcriptText, original: segments)
    }

    /// The edited text as segments, one per non-empty line, so nothing the user removed survives.
    ///
    /// - When the lines still align one-for-one with `original` (same count, same visible whole
    ///   second), each line keeps its original segment's precise start, end and speaker — the
    ///   exporter's rule, and the common case of a correction inside lines.
    /// - Otherwise each line is its own segment: its start is the `MM:SS` prefix it shows, or nil
    ///   when it has none (a typed line, or a joined one). A nil start is still searchable; it just
    ///   cannot be seeked or offered as "Play source".
    /// - When no original segment was timed, a leading clock-like token is prose ("3:00 PM call"),
    ///   not a timestamp, so nothing is parsed off — the F42 rule.
    public static func segments(transcriptText: String, original: [TranscriptSegment]) -> [TranscriptSegment] {
        let timed = original.contains { $0.start != nil }
        let edited = lines(transcriptText, parsingTimestamps: timed)
        if alignsWithOriginalTimings(edited, original) {
            return zip(original, edited).map { segment, line in
                TranscriptSegment(speaker: segment.speaker, start: segment.start, end: segment.end, text: line.text)
            }
        }
        return edited.map { TranscriptSegment(speaker: nil, start: $0.start, end: nil, text: $0.text) }
    }

    /// Whether edited lines still describe the original segments one-for-one, so the segments'
    /// subsecond timings can be kept under the edited text.
    static func alignsWithOriginalTimings(_ lines: [Line], _ segments: [TranscriptSegment]) -> Bool {
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
                //
                // Compared as the text the user sees, not by flooring both sides. F287 (`9bfd595`)
                // made the formatter round to the nearest second, and this check still floored, so a
                // segment starting at 30.7 s rendered as "00:31", floored to 30 against the line's
                // 31, and was read as retimed. One such line was enough for SRT/VTT to drop every
                // segment's own timing for whole-second starts and guessed ends — on an UNEDITED
                // transcript too, since the exporter reads its lines either way.
                return TranscriptFormatter.timestamp(editedStart) == TranscriptFormatter.timestamp(originalStart)
            default:
                // One side has a timestamp and the other does not — genuine drift (an edit added or
                // removed a line's timestamp), not F263's untimed-by-design case.
                return false
            }
        }
    }

    /// The text's non-empty lines, trimmed, each with its leading `MM:SS`/`H:MM:SS` parsed off when
    /// `parsingTimestamps` is true.
    static func lines(_ text: String, parsingTimestamps: Bool = true) -> [Line] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            guard parsingTimestamps else { return Line(start: nil, text: line) }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = timestampedLineRegex.firstMatch(in: line, range: range),
                  let clockRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else {
                return Line(start: nil, text: line)
            }
            let clock = line[clockRange].split(separator: ":").compactMap { Double($0) }
            guard clock.count == 2 || clock.count == 3 else {
                return Line(start: nil, text: line)
            }
            let start = clock.reduce(0) { $0 * 60 + $1 }
            return Line(
                start: start,
                text: line[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static let timestampedLineRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:\d{1,3}:)?\d{1,3}:\d{2})\s+(.+?)\s*$"#
    )
}
