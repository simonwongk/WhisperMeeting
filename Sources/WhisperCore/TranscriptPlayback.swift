import Foundation

/// Pure helpers for aligning playback position with transcript segments, so the GUI can highlight
/// the segment currently being heard and jump playback to a tapped segment. No AV framework here —
/// the view owns the player; this only does the arithmetic.
public enum TranscriptPlayback {
    /// The index of the segment whose time range contains `seconds`. Returns `nil` before the first
    /// segment, during silence gaps, and after the final segment ends. If malformed/overlapping
    /// ranges exist, the latest matching segment wins. Assumes start times are ordered as Whisper
    /// emits them.
    public static func activeIndex(
        at seconds: Double,
        in segments: [TranscriptSegment],
        recordingDuration: Double? = nil
    ) -> Int? {
        var result: Int?
        for (index, segment) in segments.enumerated() {
            guard let start = segment.start else { continue }
            if start > seconds { break }
            // Only resolve the next start when this segment is open-ended. `.lazy` stops at the
            // first following segment that has a start (the common case: the very next one) instead
            // of eagerly materializing every remaining start on each iteration — that eager scan
            // made the whole lookup O(n²) per playback tick on long transcripts.
            let effectiveEnd = segment.end
                ?? segments[(index + 1)...].lazy.compactMap(\.start).first
                ?? recordingDuration
            guard let effectiveEnd else { continue }
            if seconds < effectiveEnd { result = index }
        }
        return result
    }
}
