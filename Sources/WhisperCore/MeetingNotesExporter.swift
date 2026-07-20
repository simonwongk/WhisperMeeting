import Foundation

/// Builds a single shareable Markdown "meeting notes" document combining the Claude summary (when
/// present) with the full transcript. Pure and framework-free; the caller formats the date so the
/// output is deterministic and testable.
public enum MeetingNotesExporter {
    public static func markdown(
        title: String,
        dateText: String,
        durationSeconds: TimeInterval,
        languageCode: String?,
        summary: MeetingSummary?,
        transcriptText: String
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
                lines.append(contentsOf: summary.actionItems.map { "- [ ] \($0)" })
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(transcriptText)
        return lines.joined(separator: "\n") + "\n"
    }
}
