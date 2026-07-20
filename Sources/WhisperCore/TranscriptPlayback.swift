import Foundation

/// Pure helpers for aligning playback position with transcript segments, so the GUI can highlight
/// the segment currently being heard and jump playback to a tapped segment. No AV framework here —
/// the view owns the player; this only does the arithmetic.
public enum TranscriptPlayback {
    /// The index of the segment that should be highlighted at playback time `seconds`: the last
    /// segment whose start time is at or before `seconds`. Returns `nil` before the first segment
    /// begins. Assumes segments are ordered by start time (as Whisper emits them).
    public static func activeIndex(at seconds: Double, in segments: [TranscriptSegment]) -> Int? {
        var result: Int?
        for (index, segment) in segments.enumerated() {
            guard let start = segment.start else { continue }
            if start <= seconds {
                result = index
            } else {
                break
            }
        }
        return result
    }
}
