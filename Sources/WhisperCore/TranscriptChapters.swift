import Foundation

/// One chapter of a chaptered transcript: a `[start, end)` time range, a title (a marker's label or a
/// `Marker N` fallback), and the transcript segments that fall inside it.
public struct TranscriptChapter: Sendable, Equatable {
    public let title: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let segments: [TranscriptSegment]

    public init(title: String, start: TimeInterval, end: TimeInterval, segments: [TranscriptSegment]) {
        self.title = title
        self.start = start
        self.end = end
        self.segments = segments
    }
}

/// Pure partitioning of a transcript into chapters bounded by recording markers (F60). Timestamps
/// only — chapters are time ranges, never speakers. The audio is never read.
public enum TranscriptChapters {
    static let leadingTitle = "Introduction"
    static let wholeTitle = "Recording"

    /// Partition `[0, durationSeconds)` into chapters. Each marker starts a chapter running to the
    /// next marker (or the end). A leading chapter is prepended only when the first marker starts
    /// after 0. No markers → a single full-duration chapter. Each segment is assigned to the chapter
    /// whose `[start, end)` contains its start, so a segment starting exactly on a boundary goes to
    /// the later chapter.
    public static func chapters(
        markers: [RecordingMarker],
        segments: [TranscriptSegment],
        durationSeconds: TimeInterval
    ) -> [TranscriptChapter] {
        let duration = max(0, durationSeconds)
        let ordered = markers.sorted { $0.offset < $1.offset }
        guard !ordered.isEmpty else {
            return [TranscriptChapter(title: wholeTitle, start: 0, end: duration, segments: assign(segments, from: 0, to: duration))]
        }

        var bounds: [(start: TimeInterval, title: String)] = []
        if (ordered.first?.offset ?? 0) > 0 {
            bounds.append((0, leadingTitle))
        }
        for (index, marker) in ordered.enumerated() {
            bounds.append((min(max(0, marker.offset), duration), RecordingMarkers.displayLabel(for: marker, at: index + 1)))
        }

        return bounds.enumerated().map { index, bound in
            let end = index + 1 < bounds.count ? bounds[index + 1].start : duration
            let clampedEnd = max(bound.start, end)
            return TranscriptChapter(
                title: bound.title,
                start: bound.start,
                end: clampedEnd,
                segments: assign(segments, from: bound.start, to: clampedEnd)
            )
        }
    }

    /// A one-line-per-chapter "MM:SS Title" list.
    public static func list(_ chapters: [TranscriptChapter]) -> String {
        guard !chapters.isEmpty else { return "" }
        return chapters
            .map { "\(TranscriptFormatter.timestamp($0.start)) \($0.title)" }
            .joined(separator: "\n") + "\n"
    }

    /// A chaptered Markdown transcript: each chapter's segments grouped under a "## MM:SS Title".
    public static func markdown(_ chapters: [TranscriptChapter]) -> String {
        var lines: [String] = []
        for chapter in chapters {
            lines.append("## \(TranscriptFormatter.timestamp(chapter.start)) \(chapter.title)")
            lines.append("")
            for segment in chapter.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func assign(
        _ segments: [TranscriptSegment],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> [TranscriptSegment] {
        segments.filter { segment in
            guard let segmentStart = segment.start else { return false }
            return segmentStart >= start && segmentStart < end
        }
    }
}
