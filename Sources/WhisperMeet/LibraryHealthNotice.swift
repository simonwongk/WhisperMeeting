import Foundation
import WhisperCore

/// What WhisperMeet says about each way the meeting library can open read-only (F540).
///
/// Every sentence here is built from the `PersistedStoreHealth` the store actually holds, because a
/// sentence that is not can describe a state the library is not in. Until F540 there was one: "could
/// not fully read your meeting library … the unreadable index was copied aside", said for every
/// degraded state at launch and echoed by the banner and the Settings section. It was false for the
/// wipe shape (`.suspectEmpty`: the index read cleanly as `[]`, so nothing was unreadable and nothing
/// was copied), false for a stale-backup load (`.recoveredFromBackup` leaves the damaged index where
/// it is and copies nothing — the store's own paragraph beside it said "Nothing was written"), and
/// silent about `.divergentGenerations`, for which `docs/RECOVERY.md` has a whole section keyed on
/// the app saying "two versions of the library were found".
///
/// The switches are exhaustive with no `default`, like `PersistedStoreHealth.severity` and
/// `DamagedListNotice.description`: a new health must be described here or this stops compiling,
/// rather than silently reading as the sentence of some other state.
///
/// A sentence claims a copy only when one exists. `.recoveredFromBackup` and `.suspectEmpty` copy
/// nothing, and `.divergentGenerations` copies both files on a best-effort basis the load cannot
/// report back, so it says neither version "has been changed" — which is true whatever the copy did.
extension ReadOnlyLibraryNotice {
    /// Where Recover Library is, as the Settings window names it. Asserted against `ContentView`'s own
    /// section header, because the banner used to say "Settings → Library" for a section titled
    /// "Meeting library".
    static let recoverLibraryPath = "Settings → Meeting library → Recover Library…"

    /// What was found, for a library in this state: the sentence the standing surfaces build on.
    /// Never ends in a next step — each surface adds its own.
    static func found(_ health: PersistedStoreHealth) -> String {
        switch health {
        case .complete:
            // Not reachable from a read-only library; a sentence rather than a crash or an empty string.
            return "The meeting library loaded in full."
        case .recoveredFromBackup:
            return "The meeting index was damaged, so WhisperMeet opened its previous backup, which may be one save behind. The damaged index was left as it was, and nothing was copied aside."
        case .divergentGenerations:
            return "Two versions of the meeting library were found: the index on disk matches no save WhisperMeet recorded, and the last save it did record is still kept. WhisperMeet will not choose between them, and neither has been changed."
        case let .suspectEmpty(count):
            let recordings = count == 1 ? "1 finished recording is" : "\(count) finished recordings are"
            let them = count == 1 ? "it" : "them"
            return "The meeting index is empty, but \(recordings) in the library's Recordings folder, so WhisperMeet is open read-only instead of treating \(them) as new. The index itself read cleanly, so nothing was copied aside."
        case .partiallySalvaged:
            return "WhisperMeet could read only part of the meeting index. The meetings it could read are shown, and the records it could not read were left in the copy that was set aside."
        case let .unreadable(quarantined):
            guard !quarantined.isEmpty else {
                return "WhisperMeet could not read the meeting index or its backup, and could not copy them aside, so both are exactly where they were."
            }
            let copied = quarantined.count == 1 ? "The unreadable file was" : "The unreadable files were"
            return "WhisperMeet could not read the meeting index or its backup. \(copied) copied aside as \(quarantined.joined(separator: " and "))."
        case let .unavailable(reason):
            return "WhisperMeet could not read the meeting index at all. \(reason)"
        }
    }

    /// The paragraph `performStartupRecovery` adds when the library opened read-only.
    ///
    /// Three states carry a paragraph of the store's own beside this one — the load that threw
    /// (`.unreadable`, `.unavailable`) and the salvage (`.partiallySalvaged`) — and that paragraph
    /// already says what was read and parked and copied aside, with the names. For those this says
    /// only that the library is read-only, so the two cannot repeat or contradict each other. The
    /// other three have no paragraph of the store's that is true, so this one is the whole account.
    static func startup(for health: PersistedStoreHealth) -> String {
        switch health {
        case .complete:
            return found(health)
        case .recoveredFromBackup, .suspectEmpty:
            return "\(found(health)) Your recordings are untouched. Nothing will be changed until you choose how to recover."
        case .divergentGenerations:
            return "\(found(health)) Your recordings are untouched. Nothing will be changed until you choose which version to keep: Recover Library… in Settings goes back to the last save WhisperMeet recorded, and Recovery in the documentation says how to keep the version on disk instead."
        case .partiallySalvaged, .unreadable, .unavailable:
            return "WhisperMeet is open in read-only mode because it could not fully read your meeting library. Your recordings are untouched. Nothing will be changed until you choose how to recover."
        }
    }

    /// The standing notice above the detail column while read-only (F313). Names the way out, because
    /// the read-only state is only ever resolved by taking it.
    static func banner(for health: PersistedStoreHealth) -> String {
        switch health {
        case .divergentGenerations:
            return "\(found(health)) Your recordings are untouched. To go back to the last save WhisperMeet recorded, open \(recoverLibraryPath); to keep the version on disk instead, see Recovery in the documentation."
        case .complete, .recoveredFromBackup, .partiallySalvaged, .suspectEmpty, .unreadable, .unavailable:
            return "\(found(health)) Your recordings are untouched. To recover, open \(recoverLibraryPath)"
        }
    }

    /// The Settings → Meeting library section's read-only sentence (F313): what is true of the library,
    /// beside the controls that resolve it, with nothing about menus or transcripts.
    static func librarySectionNotice(for health: PersistedStoreHealth) -> String {
        switch health {
        case .divergentGenerations:
            return "\(found(health)) Your recordings are untouched. Recover Library goes back to a save WhisperMeet recorded; to keep the version on disk instead, see Recovery in the documentation."
        case .complete, .recoveredFromBackup, .partiallySalvaged, .suspectEmpty, .unreadable, .unavailable:
            return "\(found(health)) Your recordings are untouched. Recover Library restores an earlier copy of the index, or rebuilds one from the recording folders when no copy was kept."
        }
    }

    /// What Recover Library and the folder rebuild say when they wrote an index and the library is
    /// still read-only (F193, F289). The index they wrote can be in any state, and an empty copy beside
    /// finished recordings is the one the rehearsal in `docs/RECOVERY.md` walks into on purpose — so
    /// this says what the library is now, not "could not fully read".
    static func stillReadOnly(afterWriting what: String, _ health: PersistedStoreHealth) -> String {
        "\(what), but WhisperMeet stays in read-only mode. \(found(health)) Your recordings are untouched."
    }
}
