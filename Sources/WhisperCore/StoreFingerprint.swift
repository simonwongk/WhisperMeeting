import Foundation

/// A 64-bit content fingerprint for a store payload (F190).
///
/// Accident detection, NOT tamper resistance: it answers "are these the same bytes I recorded"
/// against a torn write, a foreign overwrite, a half-restored file or a stale sidecar. It makes no
/// claim against an adversary, and nothing in this module may be built as if it did. Every
/// comparison in the transaction module pairs it with `byteCount`.
///
/// Four independent lanes so the multiply chain is not serial. Re-measured on this Mac (M3 Pro,
/// `swiftc -O`, 2.1 MB, 50 iterations): **0.246 ms four-lane (8.6 GB/s) against 0.640 ms one-lane**.
/// The design quoted 0.403 ms vs 2.59 ms — a wider ratio than reproduces here, but the conclusion is
/// the same and the absolute cost is lower than it promised. Under `swift test` (debug) the same
/// call takes ~2.0 ms; that is the build, not the algorithm, and is not worth optimising for.
///
/// `CryptoKit` is a framework import and is barred from `WhisperCore` by the purity rule; a
/// pure-Swift SHA-256 would cost an order of magnitude more for a property this design does not
/// need.
///
/// The algorithm is fixed by `docs/LIBRARY_INDEX_TRANSACTION_DESIGN.md` §2.1 and is part of the
/// on-disk format: a ledger written by one build is compared against bytes fingerprinted by
/// another, so any reimplementation must produce identical output.
/// `storeFingerprintMatchesItsPublishedGoldenValues` pins that — changing the mixer is a format
/// change, not a refactor.
public enum StoreFingerprint {
    /// 16 lowercase hex characters.
    public static func of(_ data: Data) -> String {
        var a = 0x9E37_79B9_7F4A_7C15 ^ UInt64(data.count)
        var b: UInt64 = 0xBF58_476D_1CE4_E5B9
        var c: UInt64 = 0x94D0_49BB_1331_11EB
        var e: UInt64 = 0x2545_F491_4F6C_DD1D

        data.withUnsafeBytes { raw in
            let count = raw.count
            var i = 0
            // Four lanes per 32-byte block. `loadUnaligned` because a `Data` slice carries no
            // alignment guarantee, and the store payload is a slice of whatever the decoder handed
            // back.
            while i + 32 <= count {
                a = mix(a, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                b = mix(b, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)))
                c = mix(c, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)))
                e = mix(e, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)))
                i += 32
            }
            // FNV-1a over the tail, into lane `a` only — the tail is at most 31 bytes and spreading
            // it over four lanes would cost a branch per byte for no additional mixing.
            while i < count {
                a = (a ^ UInt64(raw[i])) &* 0x0000_0100_0000_01B3
                i += 1
            }
        }

        var h = a ^ (b &* 0xC2B2_AE3D_27D4_EB4F) ^ ((c << 17) | (c >> 47)) ^ (e &+ 0x9E37_79B9_7F4A_7C15)
        h ^= h >> 33
        h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 29
        h = h &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 32
        return String(format: "%016llx", h)
    }

    /// The design's mixer, verbatim. `&*`/`&+` are required: this is a hash, so wrapping IS the
    /// arithmetic, and a trapping overflow here would crash on ordinary input.
    private static func mix(_ h: UInt64, _ w: UInt64) -> UInt64 {
        var x = h ^ w
        x = x &* 0xFF51_AFD7_ED55_8CCD
        return ((x << 31) | (x >> 33)) &+ 0x1656_67B1_9E37_79F9
    }
}
