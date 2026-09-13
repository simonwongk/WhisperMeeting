import Foundation

/// A stable fingerprint over a transcript's *timings only*, used to detect that a cached speaker
/// overlay no longer describes the current segments (F218).
///
/// Deliberately not a cryptographic hash: `CryptoKit` is a framework import barred from WhisperCore,
/// and the threat model here is accidental drift — a re-run, a segment splice — not forgery. FNV-1a
/// over the quantized bounds is enough to notice a change, and it is dependency-free. This is the
/// same argument `docs/LIBRARY_INDEX_TRANSACTION_DESIGN.md` records for `StoreFingerprint`.
public enum TranscriptTimingFingerprint {
    /// Milliseconds. Finer resolution would make the fingerprint sensitive to float formatting;
    /// coarser would miss a real re-alignment.
    private static let quantum: Double = 1000

    /// A segment with no timing at all. Reserved so it can never collide with a real quantized bound.
    private static let missingTiming = UInt64.max

    /// A finite bound too large to quantize into `Int64`. A transcript is editable JSON on disk, so a
    /// bound can be any finite `Double`; converting one straight to `Int64` traps the process, which
    /// is a crash caused by data rather than by code.
    private static let unquantizableTiming = UInt64.max &- 1

    public static func compute(_ segments: [TranscriptSegment]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // The count is mixed in first so a prefix can never fingerprint as the whole.
        mix(UInt64(truncatingIfNeeded: segments.count))
        for segment in segments {
            mix(quantized(segment.start))
            mix(quantized(segment.end))
        }
        return String(format: "%016llx", hash)
    }

    /// `nil` maps to a reserved sentinel so a segment without timings can never fingerprint the same
    /// as one that genuinely starts at zero; an out-of-range bound maps to a second sentinel so a
    /// malformed transcript degrades the fingerprint instead of trapping.
    private static func quantized(_ value: Double?) -> UInt64 {
        guard let value, value.isFinite else { return missingTiming }
        guard let scaled = Int64(exactly: (value * quantum).rounded()) else {
            return unquantizableTiming
        }
        return UInt64(bitPattern: scaled)
    }
}
