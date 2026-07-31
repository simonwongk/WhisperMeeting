import Foundation

/// Maps a transcript segment's time span to a byte range in `meeting.wav`, using the fixed 16-bit
/// mono PCM layout `WAVWriter` writes (44-byte header, 2 bytes/sample). Pure — the app reads that byte
/// range to slice a clip for re-transcription (F77).
public enum SegmentAudioRange {
    public static let headerBytes = 44
    public static let bytesPerSample = 2

    public static func byteRange(startSeconds: Double, endSeconds: Double, sampleRate: Int) -> Range<Int> {
        let startByte = headerBytes + Int(startSeconds * Double(sampleRate)) * bytesPerSample
        let endByte = headerBytes + Int(endSeconds * Double(sampleRate)) * bytesPerSample
        return startByte..<max(startByte, endByte)
    }
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
