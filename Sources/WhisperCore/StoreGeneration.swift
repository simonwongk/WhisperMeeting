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

    /// The token for "I looked, and there was no file" (F864).
    ///
    /// `BackupJSONStore.load()` returns nil when neither copy exists, so a store opened on a fresh
    /// library has read no generation — and with no token its first save was unchecked, so the
    /// second of two copies to save replaced the first copy's index. A caller that found no file
    /// passes this instead: a save over no file installs exactly as before, with no parent, and a
    /// file that appeared meanwhile is a lost race (`BackupJSONStore`'s compare-and-swap, rule 3a).
    ///
    /// A value rather than a new stored field, so the type's shape is unchanged. Its fingerprint is
    /// not sixteen hex digits and its byte count is negative, so it matches no bytes, empty ones
    /// included. It is never written to a ledger: a save over no file has no parent.
    ///
    /// What a save expecting it does is the same for a file that is there but does not decode: it
    /// proceeds (the save copies such a file aside first, and rule 3 lets it through whatever the
    /// token), and any decodable file is a lost race. So it is also what a damaged list's load keeps for Keep This List when its
    /// file was missing or did not decode (`LoadResult.primaryAsRead`, F865): nobody can have
    /// written a decodable file there since except another writer.
    public static let absent = GenerationToken(
        sequence: 0, fingerprint: "absent", byteCount: -1, writer: "none", verified: false
    )

    /// Whether this is `absent` — compared on content, like every other question asked of a token.
    public var expectsNoFile: Bool {
        fingerprint == Self.absent.fingerprint && byteCount == Self.absent.byteCount
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
