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
    private func persist() {
        do {
            try store.save(log)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
