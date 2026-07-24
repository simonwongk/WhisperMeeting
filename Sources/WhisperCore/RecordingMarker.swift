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

    /// How long after a segment ends a marker can still borrow that segment as its context. A
    /// marker dropped in a brief pause keeps the utterance that just ended; one dropped deep into
    /// silence gets no context (rather than a stale, unrelated line from minutes earlier).
    static let contextGapTolerance: TimeInterval = 5

    /// The transcript segment to show as a marker's context: the segment whose `[start, end)`
    /// contains `offset`, or — if the marker landed in a short pause — the segment that just ended
    /// (within `contextGapTolerance`). `nil` when the marker is deep in silence with no nearby
    /// speech, or when no segment applies.
    public static func segmentText(
        at offset: TimeInterval,
        in segments: [TranscriptSegment]
    ) -> String? {
        // Sort by start so the "last segment starting before the offset" fallback is correct even
        // if the input is out of order (Whisper output is chronological, but don't rely on it).
        let ordered = segments.sorted { ($0.start ?? -1) < ($1.start ?? -1) }
        var best: TranscriptSegment?
        var containsOffset = false
        for segment in ordered {
            guard let start = segment.start, start <= offset else { continue }
            best = segment
            if let end = segment.end, offset < end {
                containsOffset = true
                break
            }
            containsOffset = false
        }
        guard let best else { return nil }
        // Marker fell after this segment ended (a pause). Only borrow it as context if the marker
        // is close after the end; a marker far into silence has no relevant nearby speech to show.
        if !containsOffset, let end = best.end, offset - end > contextGapTolerance {
            return nil
        }
        let text = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
