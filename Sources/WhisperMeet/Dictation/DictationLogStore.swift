// Sources/WhisperMeet/Dictation/DictationLogStore.swift
import Foundation
import WhisperCore

/// Persists the dictation history (`DictationLog`) to disk with the same crash-safe double-write
/// pattern used for `meetings.json`/`vocabulary.json`. `DictationView` observes `log` to show
/// dictation history in the UI.
@MainActor final class DictationLogStore: ObservableObject {
    @Published private(set) var log = DictationLog()
    /// Load health for the dictation history (F187). The previous `try?` discarded the failure with no
    /// alert, no startup message and no storage error, so the next dictation destroyed the history.
    @Published private(set) var health: PersistedStoreHealth = .complete

    /// Why the history is read-only, or nil when it is not (F187, reshaped by F195).
    ///
    /// **Computed from `health`, with no stored copy and no setter.** It used to be a stored
    /// property carrying *both* load- and save-time failures, which `persist()` cleared on a
    /// successful save. That erasure was unreachable only through a three-part unwritten invariant:
    /// `health` assigned solely in `init`, the load message set solely on that init's
    /// `!allowsMutation` branch, and `allowsMutation` being exactly `self == .complete` — the last
    /// of which lives in `WhisperCore`, a module away. Unlike `MeetingStore`, which re-states its
    /// notice on every refused mutation, this store had no re-set path, so a stray clear would have
    /// blanked the notice permanently for the process.
    ///
    /// Deriving it deletes the state the invariant was protecting. There is nothing left to erase,
    /// so the invariant stops being load-bearing rather than being documented more firmly. The
    /// separate `saveErrorMessage` below is the other half of the fix: the two failures are
    /// different events with different meanings and no longer share a channel.
    var loadErrorMessage: String? {
        guard !health.allowsMutation else { return nil }
        if case let .unavailable(reason) = health { return reason }
        return "Your dictation history could not be fully read, so it is shown read-only and nothing will be written over it."
    }

    /// Why the last save failed, or nil when the last one succeeded (F195).
    ///
    /// Separate from the load notice because they are different events: this one is about a write
    /// that just failed and may succeed next time, and it is cleared by a save that works.
    @Published private(set) var saveErrorMessage: String?

    /// Set when `clear()` could not fully remove every on-disk copy of the pre-clear history, or
    /// nil when the last Clear All fully succeeded (F456). Deliberately its own channel rather than
    /// `saveErrorMessage`: that one reads as "the last dictation could not be saved", which is the
    /// wrong sentence after an erase failure and would also be silently overwritten by the very
    /// next dictation recorded.
    @Published private(set) var historyEraseFailureMessage: String?

    /// Why earlier versions of the history are not being kept, or nil while they are (F678).
    ///
    /// `BackupJSONStore.save` reports `.historyUnavailable` when `dictation-log.history` cannot be
    /// used — a file squatting the name, a folder that cannot be written — and the save still
    /// succeeds, so nothing else would say it. Its own channel: it is not a failed save
    /// (`saveErrorMessage`), and it describes the history folder, not this dictation. Set by the first
    /// save that reports it and cleared by a save that keeps a past version again, so it says what is
    /// true now and appears once per session while the cause lasts.
    @Published private(set) var historyNotice: String?

    /// Whether the next dictation would go unrecorded (F195).
    ///
    /// Exists so the UI can say so **before** the user holds the hotkey. The read-only banner lived
    /// under the History heading, below the dictation controls, so someone spoke into a log that
    /// would not keep it and found out afterwards. `DictationController` calls `record` from three
    /// places, all behind the same guard, and none of them could warn in advance.
    var historyWillNotRecord: Bool { !health.allowsMutation }

    /// What to tell the user before they dictate, or nil when the history is fine (F195).
    ///
    /// Phrased as what will happen to the next dictation rather than as a description of file
    /// health: they are about to speak, and "your history is read-only" does not tell them the
    /// words they are about to say will not be kept. The dictation itself still works — it is
    /// pasted and copyable — so this is about the history and says so.
    var preDictationWarning: String? {
        guard historyWillNotRecord else { return nil }
        return "Dictation still works, but it will not be saved to this history until the unreadable history file is repaired or removed."
    }
    private let store: BackupJSONStore<DictationLog>
    /// The generation this store last read or wrote, threaded into the next save so the
    /// compare-and-swap can fire (F190). `.absent` after a load that found no file (F905, F864).
    /// A plain token, NOT a health input: `health` is the load verdict and a lost race says nothing
    /// about whether the bytes on disk were readable. A lost race re-reads the history (`persist`,
    /// F905), which refreshes this token with the re-read's, and `health` only as any load does.
    private var token: GenerationToken?
    /// Test-only seam (nil in production): called between `clear()`'s two saves. A real
    /// `BackupJSONStore.save` failure (a `generationConflict` from a rival writer, an EIO, a
    /// permission hiccup) can land on either save, and this is the only way to make it land on
    /// *just* the second one while the first still succeeds normally — which is exactly the case
    /// `forgetHistory()` must not run through (F456).
    var betweenClearSavesForTesting: (() -> Void)?

    init(directory: URL? = nil) {
        let dir = directory ?? WhisperMeetLibrary.root()   // F312
        store = BackupJSONStore(
            primaryURL: dir.appendingPathComponent("dictation-log.json"),
            backupURL: dir.appendingPathComponent("dictation-log.backup.json"),
            // The dictation log is one object rather than an array, so there is no element count to
            // pin retention's high-water rule on. Its own retention policy is correspondingly
            // shallower — `RetentionPolicy.dictationLog` (F190).
            retention: .dictationLog
        )
        do {
            if let loaded = try store.load() {
                log = loaded.value
                health = loaded.health
                token = loaded.token
            } else {
                // No history on disk yet: the first save expects none (F905, as F864 did for the
                // meeting index), so another copy's first save made meanwhile is a lost race that
                // is re-read below, not a file this copy's first dictation replaces.
                token = .absent
            }
        } catch {
            // `health` alone, since F195: `loadErrorMessage` reads the reason back out of it.
            health = .unavailable(error.localizedDescription)
        }
    }

    /// Mutations are refused while the history is not known-complete (F187), so an unreadable log is
    /// preserved by `BackupJSONStore` rather than replaced by a fresh one-entry file.
    func record(
        text: String,
        outcome: DictationLogEntry.Outcome,
        rawText: String? = nil,
        refinement: String? = nil,
        timings: DictationTimings = DictationTimings(),
        truncated: Bool = false
    ) {
        guard health.allowsMutation else { return }
        let entry = DictationLogEntry(
            id: UUID(), date: Date(), text: text, outcome: outcome,
            rawText: rawText, refinement: refinement, timings: timings,
            // Written only when true (F1016), so an ordinary dictation keeps its pre-F1016 bytes.
            truncated: truncated ? true : nil
        )
        persist({ $0.adding(entry) }, afterALostRace: .makeAgain)
        if saveErrorMessage != nil { unsavedEntryIDs.insert(entry.id) }
    }

    /// Dictations this copy has recorded whose save has not landed yet (F988). A save that fails for
    /// an ordinary reason keeps its entry in `log`, and the next lost race's re-read used to replace
    /// `log` with what is on disk and make only its own change again, so a dictation still waiting
    /// vanished. The re-read carries these over by `id`. Emptied by every save that lands, since that
    /// save wrote them — so a dictation already saved is never carried back over another copy's
    /// Clear All.
    private var unsavedEntryIDs: Set<UUID> = []

    /// Erases the whole history — not just the primary file (F456).
    ///
    /// A plain single save of the cleared value is not an erase: `BackupJSONStore.save` rotates
    /// the OUTGOING (still-full) primary into `dictation-log.backup.json` and retains the
    /// incoming (now-cleared) value as one new generation in `dictation-log.history/`, leaving
    /// every earlier, still-full generation exactly where retention already had it. So a plain
    /// `persist()` here would leave the pre-clear text sitting in the backup and in history,
    /// indefinitely — recoverable by opening either file directly.
    ///
    /// The second `persist()`'s outgoing primary is the value the first one just wrote (already
    /// cleared), so it rotates THAT into the backup, overwriting the stale full copy.
    /// `forgetHistory()` then discards every retained generation — full and cleared alike; it does
    /// not touch the backup, which is exactly why the second save had to run first.
    ///
    /// `forgetHistory()` runs ONLY once both saves are confirmed to have succeeded (F456 follow-up
    /// review). It used to run unconditionally, straight after the two `persist()` calls: if the
    /// first save succeeded (primary cleared, backup rotated to the full pre-clear text — the
    /// honest, still-recoverable state at that point) and the second then failed on anything
    /// transient (`generationConflict`, an EIO, a permission hiccup), `forgetHistory()` still ran
    /// and destroyed every retained generation — including generations from BEFORE this clear —
    /// while the backup still held the full pre-clear text with no history left to fall back to.
    /// A save failure must defer, never destroy: keep history, say so, and let the user retry.
    @discardableResult
    func clear() -> Bool {
        guard health.allowsMutation else { return false }
        // A save that loses to another copy shows what that copy saved and reports the failure
        // below (F905): the history has a dictation the person has not seen, so the erase is theirs
        // to ask for again — and the token is fresh, so asking again works.
        let shown = log
        let onlyInMemory = persist({ $0.cleared() }, afterALostRace: .showWhatIsOnDisk)
        guard saveErrorMessage == nil else {
            // Nothing was cleared, so the list goes back to what the file holds (F1017): an
            // ordinary failure used to leave the cleared value in memory, so the window showed an
            // empty history under "not cleared", and the next dictation's save finished the erase
            // without `forgetHistory`. (A lost race already shows the file's, F905.)
            if onlyInMemory { log = shown }
            // Not a second save: with the token fresh after a lost race it
            // would land, and erase the dictation the other copy just saved (F905).
            historyEraseFailureMessage =
                "Dictations were not cleared, because the history could not be saved. Try Clear All again."
            return false
        }
        betweenClearSavesForTesting?()
        persist({ $0.cleared() }, afterALostRace: .showWhatIsOnDisk)
        guard saveErrorMessage == nil else {
            historyEraseFailureMessage =
                "Dictations were cleared, but an earlier copy may still be on disk because a save failed. Try Clear All again."
            return false
        }
        do {
            try store.forgetHistory()
        } catch {
            historyEraseFailureMessage =
                "Dictations were cleared, but their saved history copies could not be fully removed: \(error.localizedDescription)"
            return false
        }
        historyEraseFailureMessage = nil
        return true
    }

    /// A failed save — including a refused write because undecodable bytes could not be copied aside —
    /// is surfaced rather than swallowed by `try?` (F187).
    ///
    /// Touches `saveErrorMessage` only (F195). The load notice is derived from `health` and has no
    /// setter, so the erasure this method used to be capable of is gone by construction rather than
    /// by an invariant spanning two modules — see `loadErrorMessage` for what that invariant was.
    ///
    /// What a save that lost to another copy of the app does next (F905).
    private enum LostRaceResponse {
        /// Re-read the history and make the change again on what the other copy saved — a dictation
        /// is added to it (`MeetingStore.commitListChange`'s shape, F663).
        case makeAgain
        /// Re-read the history and show it, saying the save did not land: Clear All over a history
        /// the other copy has just added to is the person's to ask for again, not this store's to
        /// finish for them — a failure defers, it does not destroy (F456).
        case showWhatIsOnDisk
    }

    /// Makes `change` to the log and saves it. A save that loses to another copy of the app (F905)
    /// re-reads the history — so the token is fresh and the next save is compared against what is
    /// on disk — and then does what `afterALostRace` says. Before this the lost race was only
    /// reported: the token stayed stale, so every later dictation failed the same compare-and-swap
    /// until a relaunch, and lived only in memory. One retry: a second loss is said.
    ///
    /// Returns true when the change is in `log` but not on disk and no re-read replaced it — an
    /// ordinary save failure, or a lost race whose re-read itself failed (F1017).
    @discardableResult
    private func persist(_ change: (DictationLog) -> DictationLog, afterALostRace: LostRaceResponse) -> Bool {
        log = change(log)
        do {
            let outcome = try store.save(log, expecting: token)
            token = outcome.token
            saveErrorMessage = nil
            unsavedEntryIDs.removeAll()
            noteHistory(after: outcome)
            return false
        } catch {
            // Deliberately does NOT touch `health`, including on a lost race (F190). `health` is the
            // *load* verdict: a write that failed says nothing about whether the bytes on disk were
            // readable, and conflating them would turn a transient save failure into a permanent
            // read-only library.
            saveErrorMessage = error.localizedDescription
            guard WriteConflictReport(error).isRace else { return true }
            // The re-read IS a load, so its verdict is `health`'s to keep: a history the other copy
            // left undecodable is shown read-only, and the change waits in memory as any refused one.
            // What this copy recorded earlier and has not saved, oldest first, taken before the
            // re-read replaces `log` (F988). The entry `change` adds is not among them: `record`
            // marks it waiting only once this save has failed for good.
            let waiting = log.entries.filter { unsavedEntryIDs.contains($0.id) }.reversed()
            let reread: BackupJSONStore<DictationLog>.LoadResult?
            do {
                reread = try store.load()
            } catch {
                health = .unavailable(error.localizedDescription)
                return true
            }
            if let reread {
                health = reread.health
                token = reread.token
                log = reread.value
                guard health.allowsMutation else { return false }
            } else {
                token = .absent
                log = DictationLog()
            }
            guard afterALostRace == .makeAgain else { return false }
            let onDisk = Set(log.entries.map(\.id))
            for entry in waiting where !onDisk.contains(entry.id) {
                log = log.adding(entry)
            }
            log = change(log)
            do {
                let outcome = try store.save(log, expecting: token)
                token = outcome.token
                saveErrorMessage = nil
                unsavedEntryIDs.removeAll()
                noteHistory(after: outcome)
                return false
            } catch {
                saveErrorMessage = error.localizedDescription
                return true
            }
        }
    }

    /// Sets or clears `historyNotice` from what a successful save found about the history (F678).
    private func noteHistory(after outcome: BackupJSONStore<DictationLog>.SaveOutcome) {
        for case let .historyUnavailable(reason) in outcome.repairs {
            if historyNotice == nil {
                historyNotice = "Your dictations are being saved, but WhisperMeet cannot keep earlier versions of the dictation history right now (\(reason)). Until that is fixed, a dictation history that is changed by mistake cannot be brought back from its saved versions."
            }
            return
        }
        if outcome.retainedName != nil { historyNotice = nil }
    }
}
