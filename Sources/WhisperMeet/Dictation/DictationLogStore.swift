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
    @Published private(set) var loadErrorMessage: String?
    private let store: BackupJSONStore<DictationLog>

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperMeet", isDirectory: true)
        store = BackupJSONStore(
            primaryURL: dir.appendingPathComponent("dictation-log.json"),
            backupURL: dir.appendingPathComponent("dictation-log.backup.json")
        )
        do {
            if let loaded = try store.load() {
                log = loaded.value
                health = loaded.health
                if !loaded.health.allowsMutation {
                    loadErrorMessage = "Your dictation history could not be fully read, so it is shown read-only and nothing will be written over it."
                }
            }
        } catch {
            health = .unavailable(error.localizedDescription)
            loadErrorMessage = error.localizedDescription
        }
    }

    /// Mutations are refused while the history is not known-complete (F187), so an unreadable log is
    /// preserved by `BackupJSONStore` rather than replaced by a fresh one-entry file.
    func record(text: String, outcome: DictationLogEntry.Outcome) {
        guard health.allowsMutation else { return }
        log = log.adding(DictationLogEntry(id: UUID(), date: Date(), text: text, outcome: outcome))
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
    /// `loadErrorMessage` also carries the *load* failure, so clearing it here would in principle erase
    /// the read-only notice `DictationView` renders. It cannot today, and the reason is a three-part
    /// invariant worth writing down because it spans a module boundary (F187):
    /// 1. `health` is `private(set)` and assigned **only in `init`** — no later transition exists.
    /// 2. The load message is set only on the `!allowsMutation` branch of that same `init`.
    /// 3. `allowsMutation` (in `WhisperCore`) is exactly `self == .complete`.
    /// Every caller of `persist()` is behind a `guard health.allowsMutation`, so reaching this line
    /// means `health == .complete`, which means `init` left `loadErrorMessage` nil and only a save error
    /// can be standing in it. Unlike `MeetingStore`, which re-states its notice on every refused
    /// mutation, this store sets the load message once with no re-set path — so if any of the three
    /// parts above changes (a mutable `health`, a second message assignment, a widened
    /// `allowsMutation`), a stray clear would blank the notice permanently for the process. Split the
    /// property into load- and save-error channels before loosening any of them.
    private func persist() {
        do {
            try store.save(log)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
