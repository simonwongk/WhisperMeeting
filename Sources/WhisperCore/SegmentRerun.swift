import Foundation

/// Maps a transcript segment's time span to a byte range in `meeting.wav`, using the fixed 16-bit
/// mono PCM layout `WAVWriter` writes (44-byte header, 2 bytes/sample). Pure — the app reads that byte
/// range to slice a clip for re-transcription (F77).
public enum SegmentAudioRange {
    public static let headerBytes = 44
    public static let bytesPerSample = 2

    /// Maps a segment's span to a byte range, bounded by the recording that will be read.
    ///
    /// `availableBytes` defaults to "unbounded" only so an existing caller keeps compiling; pass the
    /// real file size. The bound is what turns an absurd timestamp into a readable range rather than
    /// merely a non-trapping one, and the caller already has the number — `AppModel.makeSegmentClip`
    /// reads `fileSize` two lines before it calls this.
    public static func byteRange(
        startSeconds: Double,
        endSeconds: Double,
        sampleRate: Int,
        availableBytes: Int = .max
    ) -> Range<Int> {
        let limit = max(headerBytes, availableBytes)
        let startByte = min(byteOffset(forSeconds: startSeconds, sampleRate: sampleRate), limit)
        let endByte = min(byteOffset(forSeconds: endSeconds, sampleRate: sampleRate), limit)
        return startByte..<max(startByte, endByte)
    }

    /// F362. `Int(Double)` **traps** rather than saturating, and both halves of the usual mistake were
    /// present here: the conversion was unguarded, and the caller's clamp — which exists — ran *after*
    /// it, where it can never help. `isFinite` alone is not the fix either, because `1e30` is perfectly
    /// finite and far past `Int.max`; the value arrives from a `meetings.json` that decoded cleanly.
    ///
    /// So the bound is applied in the `Double` domain, before any conversion, and the conversion itself
    /// is `Int(saturating:)`. The cap is expressed in *samples* and leaves room for the
    /// `* bytesPerSample` multiply and the `+ headerBytes` that follow, so the arithmetic after the
    /// clamp cannot overflow either — a saturated value that then overflows the next operation is the
    /// second-order bug AGENTS.md warns a "did not crash" test will miss.
    private static func byteOffset(forSeconds seconds: Double, sampleRate: Int) -> Int {
        guard seconds.isFinite, sampleRate > 0 else { return headerBytes }
        let samples = (seconds * Double(sampleRate)).rounded()
        // Constant first in `max`, which is what makes it NaN-sanitizing: `max(0, .nan)` evaluates
        // `.nan >= 0` as false and returns 0. The `isFinite` guard above already covers NaN; the order
        // is kept anyway so the expression does not depend on a guard two lines away staying there.
        let bounded = min(maximumSampleOffset, max(0, samples))
        return headerBytes + Int(saturating: bounded) * bytesPerSample
    }

    /// 2^40 samples — about 2.2 years at 16 kHz, so it cannot truncate a real recording, while
    /// `2^40 * 2 + 44` stays nine orders of magnitude below `Int.max`.
    private static let maximumSampleOffset = Double(1 << 40)
}

/// Splices a segment's re-run back into a transcript, re-anchoring the re-run's clip-relative
/// timestamps by the original segment's start and re-flowing order (F77).
public enum TranscriptSegmentSplice {
    public static func splice(
        _ segments: [TranscriptSegment],
        replacingIndex index: Int,
        with replacements: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard segments.indices.contains(index) else { return segments }
        let offset = segments[index].start ?? 0
        let anchored = replacements.map { replacement in
            TranscriptSegment(
                speaker: replacement.speaker,
                start: replacement.start.map { $0 + offset },
                end: replacement.end.map { $0 + offset },
                text: replacement.text
            )
        }
        var result = segments
        result.replaceSubrange(index...index, with: anchored)
        return result
    }
}
