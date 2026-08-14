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
}
