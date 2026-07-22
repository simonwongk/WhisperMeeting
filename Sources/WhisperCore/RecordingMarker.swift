import Foundation

/// A user-dropped marker flagging a moment during a recording. Pure metadata — `offset` is seconds
/// from the start of the recording; the audio is never modified. See `docs/RECORDING_MARKERS.md`.
public struct RecordingMarker: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let offset: TimeInterval
    public var label: String?

    public init(id: UUID = UUID(), offset: TimeInterval, label: String? = nil) {
        self.id = id
        self.offset = offset
        self.label = label
    }
}

/// Pure helpers for maintaining and rendering a meeting's markers.
public enum RecordingMarkers {
    /// Adds a marker, clamping a negative offset to zero, and returns the list sorted by offset.
    public static func inserting(
        _ marker: RecordingMarker,
        into markers: [RecordingMarker]
    ) -> [RecordingMarker] {
        let clamped = marker.offset < 0
            ? RecordingMarker(id: marker.id, offset: 0, label: marker.label)
            : marker
        return (markers + [clamped]).sorted { $0.offset < $1.offset }
    }

    /// The marker's own (non-blank) label, else a 1-based `"Marker N"` fallback.
    public static func displayLabel(for marker: RecordingMarker, at index: Int) -> String {
        if let label = marker.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "Marker \(index)"
    }

    /// The transcript segment active at `offset`: the segment whose `[start, end)` contains it, or
    /// failing that the last segment that started at or before it. `nil` if none applies.
    public static func segmentText(
        at offset: TimeInterval,
        in segments: [TranscriptSegment]
    ) -> String? {
        var best: TranscriptSegment?
        for segment in segments {
            guard let start = segment.start, start <= offset else { continue }
            best = segment
            if let end = segment.end, offset < end { break }
        }
        let text = best?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// A `## Markers` section for exported notes; empty when there are no markers.
    public static func markdownSection(
        markers: [RecordingMarker],
        segments: [TranscriptSegment]
    ) -> String {
        let ordered = markers.sorted { $0.offset < $1.offset }
        guard !ordered.isEmpty else { return "" }
        var lines = ["## Markers", ""]
        for (index, marker) in ordered.enumerated() {
            let label = displayLabel(for: marker, at: index + 1)
            let stamp = TranscriptFormatter.timestamp(marker.offset)
            if let context = segmentText(at: marker.offset, in: segments) {
                lines.append("- **\(stamp)** \(label) — \(context)")
            } else {
                lines.append("- **\(stamp)** \(label)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
