import Foundation

/// What happened when a ledger was written (F190).
public enum StoreLedgerWriteOutcome: Sendable, Equatable {
    case written
    /// A ledger from a newer build already sits there and was left exactly as it was.
    case refusedNewerFormat
}

/// The commit record for a persisted store. Written last; its atomic rename IS the commit (F190).
///
/// **The ledger is advisory, and that rule is load-bearing.**
///
/// > **Invariant L:** a ledger that is missing, unreadable, undecodable, or carries an unknown
/// > `formatVersion` is treated as *no ledger*, and the store behaves exactly as it did before F190.
///
/// Four separate requirements depend on Invariant L and fail together if it is ever relaxed:
///
/// - a restore that brings back `meetings.json` without its ledger must read `.complete`, not
///   damaged;
/// - `docs/RECOVERY.md` tells the user to hand-copy index files, and a hand-copy must never brick
///   the library;
/// - deleting this file is the documented manual exit from a divergence read-only state;
/// - an old bundle that writes the two legacy files and knows nothing about the ledger must not be
///   destructive.
///
/// The ledger is also never the only record of a generation: history file names carry the
/// fingerprint, so a generation is self-identifying without any ledger record. A lost ledger update
/// degrades to a directory scan; it can never lose a generation.
public struct StoreLedger: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    /// One generation's identity. `fingerprint` + `byteCount` are the identity; `sequence` only
    /// orders and names, so a writer that resets or forges the number cannot thereby claim to have
    /// read bytes it never read.
    public struct Record: Codable, Sendable, Equatable {
        public var sequence: UInt64
        public var fingerprint: String
        public var byteCount: Int
        public var writer: String
        public var wroteAtEpochSeconds: Int
        /// nil for an adopted or bootstrap generation.
        public var parentFingerprint: String?
        /// Top-level element count; nil when unknown.
        public var recordCount: Int?
        /// File name under `<stem>.history/`; nil once pruned.
        public var historyName: String?

        public init(
            sequence: UInt64,
            fingerprint: String,
            byteCount: Int,
            writer: String,
            wroteAtEpochSeconds: Int,
            parentFingerprint: String? = nil,
            recordCount: Int? = nil,
            historyName: String? = nil
        ) {
            self.sequence = sequence
            self.fingerprint = fingerprint
            self.byteCount = byteCount
            self.writer = writer
            self.wroteAtEpochSeconds = wroteAtEpochSeconds
            self.parentFingerprint = parentFingerprint
            self.recordCount = recordCount
            self.historyName = historyName
        }
    }

    public var formatVersion: Int
    public var current: Record
    public var previous: Record?
    /// Newest first, includes `current`, bounded.
    public var history: [Record]
    /// False when this writer could not create or use `<stem>.history/`. A load NEVER declares
    /// divergence while this is false — without history there is no evidence to be sure with.
    public var historyAvailable: Bool
    /// `"shared"` | `"uid-<n>"` | `"none"`.
    public var writerRealm: String

    public init(
        formatVersion: Int = StoreLedger.currentFormatVersion,
        current: Record,
        previous: Record? = nil,
        history: [Record],
        historyAvailable: Bool,
        writerRealm: String
    ) {
        self.formatVersion = formatVersion
        self.current = current
        self.previous = previous
        self.history = history
        self.historyAvailable = historyAvailable
        self.writerRealm = writerRealm
    }

    /// Invariant L, as code. Every failure — absent, unreadable, undecodable, or a `formatVersion`
    /// this build does not know — returns nil, and nil means "behave exactly as before F190".
    ///
    /// Deliberately non-throwing. A `throws` signature would invite a caller to propagate, and a
    /// propagated ledger error is precisely how an advisory sidecar turns into something that can
    /// brick a library.
    public static func read(at url: URL, using io: StoreFileIO = .live) -> StoreLedger? {
        guard let data = try? io.read(url, .readLedger),
              let ledger = try? JSONDecoder().decode(StoreLedger.self, from: data),
              ledger.formatVersion <= currentFormatVersion
        else { return nil }
        return ledger
    }

    /// Writes the ledger, unless one from a newer build is already there.
    ///
    /// The forward fence is cheap and applies to metadata only: a user who opens their library with
    /// an older build once should not permanently lose the newer build's commit record. Reading
    /// such a ledger already yields nil (Invariant L); this stops the follow-up write from
    /// destroying it as well.
    @discardableResult
    public static func write(
        _ ledger: StoreLedger,
        to url: URL,
        using io: StoreFileIO = .live
    ) throws -> StoreLedgerWriteOutcome {
        if let data = try? io.read(url, .readLedger),
           let existing = try? JSONDecoder().decode(FormatVersionProbe.self, from: data),
           existing.formatVersion > currentFormatVersion {
            return .refusedNewerFormat
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try io.writeAtomically(try encoder.encode(ledger), url, .commit)
        return .written
    }

    /// Reads only the version field, so a ledger this build cannot decode in full is still
    /// recognised as newer rather than mistaken for corruption and overwritten.
    private struct FormatVersionProbe: Decodable {
        let formatVersion: Int
    }
}
