import Foundation

/// Builds a single shareable Markdown "meeting notes" document combining the Claude summary (when
/// present) with the full transcript. Pure and framework-free; the caller formats the date so the
/// output is deterministic and testable.
public enum MeetingNotesExporter {
    /// The date line's text: `2026-09-24 07:30 +08:00`, the wall-clock time in `timeZone` and its
    /// UTC offset, in one fixed form (POSIX locale, Gregorian calendar, 24-hour clock) (F568).
    ///
    /// It used to be `formatted(date: .abbreviated, time: .shortened)`: the host's zone AND locale,
    /// naming neither. The launch backfill rewrites a sidecar whenever its composition differs, so
    /// switching the Mac's language or 12/24-hour setting rewrote every notes.md, and a trip moved
    /// every meeting's recorded time with nothing in the file to say why. Now only a time-zone
    /// change alters the text, once per sidecar, and the offset says what changed: the instant is
    /// the same either way. Staying in one zone for good would need the creation zone in the index,
    /// a persisted field; not done here.
    public static func dateText(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm xxx"
        return formatter.string(from: date)
    }

    public static func markdown(
        title: String,
        dateText: String,
        durationSeconds: TimeInterval,
        languageCode: String?,
        summary: MeetingSummary?,
        transcriptText: String,
        notes: String? = nil,
        markers: [RecordingMarker] = [],
        segments: [TranscriptSegment] = [],
        caveats: [String] = []
    ) -> String {
        var lines = ["# \(title)", ""]

        var meta: [String] = []
        if !dateText.isEmpty { meta.append(dateText) }
        if durationSeconds > 0 { meta.append(TranscriptFormatter.clock(durationSeconds)) }
        if let languageCode, !languageCode.isEmpty { meta.append(languageCode.uppercased()) }
        if !meta.isEmpty {
            lines.append("_\(meta.joined(separator: " · "))_")
            lines.append("")
        }

        // Things that are true of the RECORDING rather than of the text, above everything they
        // qualify (F281). Placement is the feature: a caveat under the transcript is a footnote,
        // and the reader has to know the audio is incomplete before they trust the text.
        //
        // This is the F56 rule applied in the other direction. Confidence below is omitted rather
        // than fabricated, because stating a score that is not true would be a false claim; a
        // transcript that stops early with no explanation is the same false claim by omission —
        // the document reads as complete because nothing says it is not. Which is exactly the
        // document most likely to be read alone, since notes.md exists so the text survives an
        // index loss (F198).
        //
        // Deliberately not typed per-field: the caller decides which facts qualify and in what
        // order, so this stays a pure formatter with no opinion about `MeetingRecord`.
        let realCaveats = caveats
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !realCaveats.isEmpty {
            lines.append("## About this recording")
            lines.append("")
            lines.append(contentsOf: realCaveats.map { "- \($0)" })
            lines.append("")
        }

        // Per-meeting notes (an agenda / attendee scratchpad) go above the transcript. Notes are
        // never sent to Claude — they belong to the local index only (F72).
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        if let summary {
            lines.append("## Summary")
            lines.append("")
            let body = summary.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append(body)
                lines.append("")
            }
            if !summary.keyPoints.isEmpty {
                lines.append("### Key points")
                lines.append(contentsOf: summary.keyPoints.map { "- \($0)" })
                lines.append("")
            }
            if !summary.actionItems.isEmpty {
                lines.append("### Action items")
                lines.append(contentsOf: summary.actionItems.map(Self.actionItemLine))
                lines.append("")
            }
        }

        // Confidence: only for a scored, unedited transcript. An edited transcript no longer matches
        // its segments, and an unscored one carries no metrics — either way a score would be a false
        // claim, so the section is omitted rather than fabricated (F56).
        let quality = TranscriptQuality.review(segments)
        if !quality.isUnscored,
           !TranscriptFormatter.isEdited(transcriptText: transcriptText, segments: segments) {
            let cleanPercent = Int(saturating: (quality.confidence * 100).rounded())
            lines.append("## Confidence")
            lines.append("")
            lines.append("\(cleanPercent)% clean — \(quality.flagged.count) of \(quality.scoredCount) segments flagged")
            lines.append("")
            for flagged in quality.flaggedBySeverity where segments.indices.contains(flagged.index) {
                let stamp = segments[flagged.index].start.map(TranscriptFormatter.timestamp) ?? "--:--"
                let reasons = flagged.flags.map(\.reason).joined(separator: " ")
                lines.append("- **\(stamp)** \(reasons)")
            }
            if !quality.flagged.isEmpty { lines.append("") }
        }

        // Once the transcript is edited, the original segments no longer match the exported body, so
        // drop segment-derived marker context (the markers themselves still list). Keeps notes from
        // showing a "context" line that contradicts the transcript beneath it.
        let contextSegments = TranscriptFormatter.isEdited(transcriptText: transcriptText, segments: segments)
            ? []
            : segments
        let markersSection = RecordingMarkers.markdownSection(markers: markers, segments: contextSegments)
        if !markersSection.isEmpty {
            lines.append(markersSection)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(transcriptText)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A GitHub-style task line for one action item, carrying the done state and any owner/due the
    /// user entered (F177): `- [x] Ship v1 — @Alice (due: Fri)`. Timestamp/quote are review aids in
    /// the app and intentionally not exported here.
    public static func actionItemLine(_ item: ActionItem) -> String {
        var line = "- [\(item.done ? "x" : " ")] \(item.text)"
        if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            line += " — @\(owner)"
        }
        if let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            line += " (due: \(due))"
        }
        return line
    }
}
