import Foundation

/// Maps a transcript segment's time span to a byte range in `meeting.wav`, using the fixed 16-bit
/// mono PCM layout `WAVWriter` writes (44-byte header, 2 bytes/sample). Pure — the app reads that byte
/// range to slice a clip for re-transcription (F77).
/// Why a segment's span cannot be turned into a byte range (F416).
public enum SegmentAudioRangeError: Error, LocalizedError, Equatable {
    /// The span runs past the end of the recording by more than rounding explains.
    case segmentOutsideRecording

    public var errorDescription: String? {
        switch self {
        case .segmentOutsideRecording:
            return "This segment's timestamps fall outside the recording, so there is no audio to "
                + "re-transcribe. Re-transcribe the whole meeting instead."
        }
    }
}

public enum SegmentAudioRange {
    public static let headerBytes = 44
    public static let bytesPerSample = 2

    /// A span past the end of the audio by at most this much is rounding, not corruption.
    ///
    /// The last segment of a real transcript routinely ends a fraction of a second after the final
    /// sample. Without a tolerance the refusal below would fire on the one segment most likely to
    /// need a re-run, which is how a safety check earns being switched off.
    static let endToleranceSeconds = 1.0

    /// Maps a segment's span to a byte range, bounded by the recording that will be read.
    ///
    /// `availableBytes` defaults to "unbounded" only so an existing caller keeps compiling; pass the
    /// real file size. The caller already has the number — `AppModel.makeSegmentClip` reads
    /// `fileSize` two lines before it calls this.
    ///
    /// **Refuses rather than clamps (F416).** F362 made an absurd decoded timestamp non-trapping by
    /// clamping both ends to the file, and that was the wrong fallback: with a sane start and an
    /// end of `1e30` the range became `start ..< fileSize`, so `makeSegmentClip` read the whole
    /// rest of the recording on the main actor, the engine transcribed that tail, and the splice
    /// inserted it at the original index while the later segments stayed — silently duplicating
    /// every segment after it in the user's transcript. A refusal is recoverable; a rewritten
    /// transcript is not.
    public static func byteRange(
        startSeconds: Double,
        endSeconds: Double,
        sampleRate: Int,
        availableBytes: Int = .max
    ) throws -> Range<Int> {
        let limit = max(headerBytes, availableBytes)
        let startByte = byteOffset(forSeconds: startSeconds, sampleRate: sampleRate)
        let endByte = byteOffset(forSeconds: endSeconds, sampleRate: sampleRate)
        // Subtraction rather than `limit + tolerance`, which overflows when `availableBytes` is the
        // default `.max` — the second-order overflow this file already exists to avoid.
        let tolerance = max(0, sampleRate) * bytesPerSample * Int(endToleranceSeconds)
        guard startByte <= limit, endByte - tolerance <= limit else {
            throw SegmentAudioRangeError.segmentOutsideRecording
        }
        let boundedStart = min(startByte, limit)
        let boundedEnd = min(endByte, limit)
        return boundedStart..<max(boundedStart, boundedEnd)
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
    /// `2^40 * 2 + 44` (≈2.2e12) stays a factor of about 4.2 million below `Int.max` — **6.6**
    /// orders of magnitude, not the nine this comment claimed until F416 did the division.
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
        // Clamped to zero, matching `byteOffset`, which floors a negative start at the WAV header
        // (F416). The clip and its anchor have to agree about where the clip began; anchoring at a
        // negative start puts the re-run's text at a time the audio never covered.
        let offset = max(0, segments[index].start ?? 0)
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
