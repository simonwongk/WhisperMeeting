import Foundation

/// A store's position in its own write history (F190).
///
/// `fingerprint` + `byteCount` are the identity; `sequence` only orders and names. A writer that
/// resets or forges the number cannot thereby claim to have read bytes it never read, because every
/// compare-and-swap in this module compares content, never numbers.
public struct GenerationToken: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let fingerprint: String
    public let byteCount: Int
    /// 8 lowercase hex; one nonce per process.
    public let writer: String
    /// False when these bytes were adopted from a file no ledger described — a pre-F190 library, an
    /// old bundle's write, a hand-restore. Adopted generations are fully writable.
    public let verified: Bool

    public init(
        sequence: UInt64,
        fingerprint: String,
        byteCount: Int,
        writer: String,
        verified: Bool
    ) {
        self.sequence = sequence
        self.fingerprint = fingerprint
        self.byteCount = byteCount
        self.writer = writer
        self.verified = verified
    }

    /// Same bytes, whatever either side believes about sequence, writer or verification.
    public func hasSameBody(as other: GenerationToken) -> Bool {
        fingerprint == other.fingerprint && byteCount == other.byteCount
    }

    /// Whether this token describes exactly the bytes now on disk. The compare-and-swap's whole
    /// question, and it is answered on content alone.
    public func matches(fingerprint: String, byteCount: Int) -> Bool {
        self.fingerprint == fingerprint && self.byteCount == byteCount
    }
}

/// One writer identity per process (F190).
///
/// Names who wrote a generation, for the recovery list and for telling "my own crash" apart from "a
/// sibling process". It is never trusted for correctness: two processes that happened to collide on
/// a nonce would still be separated by the content compare-and-swap.
public enum StoreWriterNonce {
    public static let forThisProcess: String = {
        var value = UInt32.random(in: .min ... .max)
        // Fold in the pid so two processes started in the same instant cannot share a nonce even if
        // the RNG is seeded identically — which has happened in forked test harnesses.
        value ^= UInt32(truncatingIfNeeded: getpid()) &* 0x9E37_79B9
        return String(format: "%08x", value)
    }()
}
