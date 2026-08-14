import Foundation

/// How much of a persisted store actually loaded (F187). Anything other than `.complete` means the
/// in-memory value is NOT a faithful picture of what the user had, so no mutation may be applied —
/// see `allowsMutation`. A persistence-only guard is not enough: `MeetingStore.delete` removes the
/// recording directory before it saves the index, so a blocked save would still lose audio.
public enum PersistedStoreHealth: Sendable, Equatable {
    /// The primary copy decoded in full.
    case complete
    /// The primary failed but the backup decoded — deliberately one generation stale.
    case recoveredFromBackup
    /// Some records decoded; `parkedIdentifiers` names those that did not and were left behind.
    case partiallySalvaged(parkedIdentifiers: [String])
    /// Neither copy decoded. `quarantined` lists the preserved file names.
    case unreadable(quarantined: [String])
    /// A syntactically valid but empty index found alongside existing recording folders.
    case suspectEmpty(recordingFolderCount: Int)
    /// The store could not be read at all (I/O, permissions).
    case unavailable(String)

    /// Mutation is permitted only when the loaded value is known complete.
    public var allowsMutation: Bool {
        self == .complete
    }

    /// How bad this state is, ranked by how much of the user's data is unaccounted for (F187).
    ///
    /// Exists so a caller holding one health value for SEVERAL stores can keep the worst of them
    /// instead of the last one it happened to load — see `MeetingStore.degrade(to:)`. `.complete` is
    /// the unique rank 0, which is the whole point: a store that loaded cleanly can never raise a
    /// damaged one back to writable.
    ///
    /// The switch is exhaustive on purpose. A new case must be given a rank here or WhisperCore stops
    /// compiling, rather than silently defaulting to "nothing wrong" the way a `default:` would.
    public var severity: Int {
        switch self {
        case .complete: return 0
        // The whole value, one generation stale.
        case .recoveredFromBackup: return 1
        // Some records are gone, the rest are trustworthy.
        case .partiallySalvaged: return 2
        // Nothing loaded and folders exist, so everything appears to be missing.
        case .suspectEmpty: return 3
        // Nothing decoded at all; the bytes at least survive in quarantine.
        case .unreadable: return 4
        // The store could not even be read, so we cannot say what is or is not there.
        case .unavailable: return 5
        }
    }

    /// True when `self` describes a strictly worse load than `other`. Equal ranks are NOT worse, so the
    /// first store to report a given severity keeps its own detail (quarantine names, parked ids).
    public func isWorse(than other: PersistedStoreHealth) -> Bool {
        severity > other.severity
    }
}
