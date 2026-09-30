import Foundation

/// Parses WebVTT / SRT captions into `[TranscriptSegment]` (F183). It reads what `TranscriptExporter`
/// writes: that exporter entity-escapes `&`, `<` and `>` in cue text (F44), and this parser decodes
/// those three references back, so exported captions round-trip (F491). The one exception is SubRip text
/// that itself contains a literal `&lt;`, `&gt;` or `&amp;`: the exporter leaves `&` raw there, so that
/// output is ambiguous and decodes to the character the reference names.
///
/// Where its output goes today: `MediaDownloadClient` parses a link import's caption track, and
/// `AppModel.importFromURL` → `adoptImportedRecording` stores the result as
/// `MeetingRecord.referenceSegments`. **Nothing displays, compares or adopts those segments yet** —
/// Second Opinion compares one engine's transcript against another's and never reads them, and no
/// action copies a caption into `meeting.segments` (F491). They are kept so a future caption
/// comparison has them. It must still uphold two non-negotiable product invariants before a segment is
/// ever constructed, because a stored segment is one wiring change away from the transcript:
///
/// - **No diarization.** Broadcast/YouTube captions embed speaker labels (`>> `, `JOHN:`, `[Speaker 1]`,
///   the `<v Name>` voice tag, a leading dialogue dash). Those are stripped — including a `>>` that
///   arrives as `&gt;&gt;` — so a caption can never put speaker identity into a WhisperMeet
///   transcript (`PRODUCT_SPEC.md` § "Explicit limitation").
/// - **Original language.** Enforced upstream by pinning `--sub-langs` to the video's own language at the
///   download layer (never requesting auto-translated tracks); this parser only ever sees the pinned track.
public enum SubtitleParser {
    public static func parse(_ raw: String) -> [TranscriptSegment] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var segments: [TranscriptSegment] = []
        var index = 0
        while index < lines.count {
            guard let (start, end) = parseTiming(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index])
                index += 1
            }
            // Strip each caption LINE before joining. A cue commonly carries one speaker per line
            // ("JOHN: hi" / ">> and then we shipped"), so cleaning only the joined string would leave
            // every label after the first embedded in the segment text — speaker identity in the
            // transcript, which the no-diarization invariant forbids.
            // The joined pass strips labels only: tags and entities were handled per line, and running
            // either again would strip a decoded `<b>` as a tag or decode a `&amp;lt;` twice (F491).
            let cleaned = stripSpeakerLabels(
                textLines.map(cleanCueText).filter { !$0.isEmpty }.joined(separator: " ")
            )
            guard !cleaned.isEmpty else { continue }
            // Rolling-caption dedup: auto-captions re-emit the same line across consecutive cues with
            // shifting timings; keep the first appearance and extend its end, so the reference isn't
            // doubled. Also collapse a cue whose text merely extends the previous one.
            if let last = segments.last,
               last.text == cleaned || cleaned.hasPrefix(last.text) || last.text.hasPrefix(cleaned) {
                let longer = cleaned.count >= last.text.count ? cleaned : last.text
                segments[segments.count - 1] = TranscriptSegment(
                    speaker: nil, start: last.start, end: end, text: longer
                )
            } else {
                segments.append(TranscriptSegment(speaker: nil, start: start, end: end, text: cleaned))
            }
        }
        return segments
    }

    /// Parses a `HH:MM:SS.mmm --> HH:MM:SS.mmm` (or `,` SRT / no-hours) cue line, ignoring any trailing
    /// WebVTT cue settings (`align:`, `position:`). Returns nil for non-timing lines.
    static func parseTiming(_ line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        guard let start = clockSeconds(String(line[..<arrow.lowerBound])) else { return nil }
        // The end side may carry cue settings after the timestamp — take the first clock token only.
        let afterArrow = String(line[arrow.upperBound...])
        let endToken = afterArrow.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first { clockSeconds($0) != nil }
        guard let endToken, let end = clockSeconds(endToken) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS.mmm`, `MM:SS.mmm`, or the SRT `,` millisecond separator → seconds.
    static func clockSeconds(_ token: String) -> Double? {
        let trimmed = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard trimmed.range(of: #"^\d{1,2}:\d{2}(:\d{2})?\.\d{1,3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Strips inline tags (`<c>`, `<00:00:01.000>`, `<v Name>`), decodes the `&lt;` / `&gt;` / `&amp;`
    /// character references, then strips any leading speaker labels, so no speaker identity survives
    /// into a segment. The order matters: tags first, so an escaped `&lt;b&gt;` is kept as text rather
    /// than removed as a tag; decoding before labels, so an escaped `&gt;&gt;` chevron is still a
    /// chevron (F491). Whitespace-collapsed.
    static func cleanCueText(_ text: String) -> String {
        // Remove every angle-bracket tag (timing cues, <c> color spans, <v Name> voice spans).
        let untagged = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return stripSpeakerLabels(decodeCharacterReferences(untagged))
    }

    /// The three references `TranscriptExporter.escapeCueText` writes. `&amp;` goes last so each
    /// reference decodes exactly once: `&amp;lt;` becomes the text `&lt;`, not `<`. Other named or
    /// numeric references are left as written.
    static func decodeCharacterReferences(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Collapses whitespace, then removes leading speaker labels repeatedly, because a line can stack
    /// them (`>> JOHN:`).
    static func stripSpeakerLabels(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        var changed = true
        while changed {
            let before = result
            for pattern in speakerLabelPrefixes {
                result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            result = result.trimmingCharacters(in: .whitespaces)
            changed = result != before
        }
        return result
    }

    private static let speakerLabelPrefixes = [
        #"^>>+\s*"#,                          // `>>` chevron speaker change
        #"^-\s+"#,                            // leading dialogue dash
        #"^\[[^\]]*\]\s*:?\s*"#,             // `[Speaker 1]`, `[MUSIC]`
        #"^\((?:speaker|voice)[^)]*\)\s*:?\s*"#, // `(Speaker 1)`
        #"^[Ss]peaker\s*\d+\s*:\s*"#,        // bare `Speaker 1:`
        #"^[A-Z][A-Z0-9 .'-]{0,30}:\s+"#,   // ALL-CAPS broadcast label `JOHN:` / `JOHN SMITH:`
    ]
}
