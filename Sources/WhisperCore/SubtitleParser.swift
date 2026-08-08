import Foundation

/// Parses WebVTT / SRT captions into `[TranscriptSegment]` (F183). This is the inverse of the VTT/SRT
/// that `TranscriptExporter` already writes, so its red-green test is a clean round-trip.
///
/// It is a **write path into the transcript**, not a passive reference: the second-opinion sheet's adopt
/// action copies a caption span straight into `meeting.segments[].text`. So this parser must uphold two
/// non-negotiable product invariants before a segment is ever constructed:
///
/// - **No diarization.** Broadcast/YouTube captions embed speaker labels (`>> `, `JOHN:`, `[Speaker 1]`,
///   the `<v Name>` voice tag, a leading dialogue dash). Those are stripped, so adopting a caption can
///   never put speaker identity into a WhisperMeet transcript (`PRODUCT_SPEC.md` § "Explicit limitation").
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
            let cleaned = cleanCueText(textLines.joined(separator: " "))
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

    /// Strips inline tags (`<c>`, `<00:00:01.000>`, `<v Name>`), then any leading speaker labels, so no
    /// speaker identity survives into a segment. Applied repeatedly because a line can stack them
    /// (`>> JOHN:`). Whitespace-collapsed.
    static func cleanCueText(_ text: String) -> String {
        // Remove every angle-bracket tag (timing cues, <c> color spans, <v Name> voice spans).
        var result = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
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
