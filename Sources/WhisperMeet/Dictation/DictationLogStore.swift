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
    /// compare-and-swap can fire (F190). A plain token, NOT a health input: `health` is the load
    /// verdict and a lost race says nothing about whether the bytes on disk were readable, so a
    /// conflict is reported through `saveErrorMessage` and changes nothing else.
    private var token: GenerationToken?

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
        refinement: String? = nil
    ) {
        guard health.allowsMutation else { return }
        log = log.adding(DictationLogEntry(
            id: UUID(), date: Date(), text: text, outcome: outcome,
            rawText: rawText, refinement: refinement
        ))
        persist()
    }

    func clear() {
        guard health.allowsMutation else { return }
        log = log.cleared()
        persist()
    }

    /// A failed save — including a refused write because undecodable bytes could not be copied aside —
    /// is surfaced rather than swallowed by `try?` (F187).
    ///
    /// Touches `saveErrorMessage` only (F195). The load notice is derived from `health` and has no
    /// setter, so the erasure this method used to be capable of is gone by construction rather than
    /// by an invariant spanning two modules — see `loadErrorMessage` for what that invariant was.
    private func persist() {
        do {
            let outcome = try store.save(log, expecting: token)
            token = outcome.token
            saveErrorMessage = nil
        } catch {
            // Deliberately does NOT touch `health`, including on a lost race (F190). `health` is the
            // *load* verdict: a write that failed says nothing about whether the bytes on disk were
            // readable, and conflating them would turn a transient save failure into a permanent
            // read-only library.
            saveErrorMessage = error.localizedDescription
        }
    }
}
