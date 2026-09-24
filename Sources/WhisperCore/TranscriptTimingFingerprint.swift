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

    /// A segment with no timing at all — the `start`/`end` key was absent or null.
    private static let missingTiming = UInt64.max

    /// A bound that exists but is unusable: negative, NaN, infinite, or too large to quantize into
    /// `Int64`. A transcript is editable JSON on disk, so a bound can be any `Double`; converting
    /// one straight to `Int64` traps the process, which is a crash caused by data rather than code.
    private static let unusableTiming = UInt64.max &- 1

    /// Whether going from `old` to `new` only removed or restored whole lines: one list's
    /// `(start, end)` pairs are an in-order subsequence of the other's (F426). Text is ignored —
    /// this is about timing only, like the fingerprint itself.
    ///
    /// Speaker labels are drawn fresh from the analysis's turns and each line's own bounds, so under
    /// such a change every surviving line's label is exactly what it was, and an analysis that
    /// matched `old` still describes `new`. A line that MOVED is never compatible, however small the
    /// move: that is what a re-transcription looks like, and what the fingerprint exists to catch.
    public static func onlyAddsOrRemovesLines(from old: [TranscriptSegment], to new: [TranscriptSegment]) -> Bool {
        func isSubsequence(_ shorter: [TranscriptSegment], of longer: [TranscriptSegment]) -> Bool {
            var cursor = longer.startIndex
            for line in shorter {
                while cursor < longer.endIndex,
                      !(longer[cursor].start == line.start && longer[cursor].end == line.end) {
                    cursor += 1
                }
                guard cursor < longer.endIndex else { return false }
                cursor += 1
            }
            return true
        }
        return new.count <= old.count ? isSubsequence(new, of: old) : isSubsequence(old, of: new)
    }

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
    /// as one that genuinely starts at zero; an unusable bound maps to a second sentinel so a
    /// malformed transcript degrades the fingerprint instead of trapping.
    ///
    /// Real bounds are non-negative and quantize to at most ~10^8, so both sentinels sit far outside
    /// the reachable range and CANNOT be spelled by any real value — which is what the word
    /// "reserved" has to mean. Mapping through `UInt64(bitPattern:)` would break that: a bound of
    /// -1 ms lands exactly on `missingTiming` and -2 ms exactly on `unusableTiming`, so two
    /// different timing sets would share one fingerprint in the function whose whole job is to
    /// notice that timings differ.
    private static func quantized(_ value: Double?) -> UInt64 {
        guard let value else { return missingTiming }
        guard value.isFinite,
              let scaled = Int64(exactly: (value * quantum).rounded()),
              scaled >= 0,
              UInt64(scaled) < unusableTiming else {
            return unusableTiming
        }
        return UInt64(scaled)
    }
}
