// Sources/WhisperMeet/Dictation/DictationLogStore.swift
import Foundation
import WhisperCore

/// Persists the dictation history (`DictationLog`) to disk with the same crash-safe double-write
/// pattern used for `meetings.json`/`vocabulary.json`. No UI reads this yet — it exists so outcomes
/// are captured now and a future history view can simply observe `log`.
@MainActor final class DictationLogStore: ObservableObject {
    @Published private(set) var log = DictationLog()
    private let store: BackupJSONStore<DictationLog>

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperMeet", isDirectory: true)
        store = BackupJSONStore(
            primaryURL: dir.appendingPathComponent("dictation-log.json"),
            backupURL: dir.appendingPathComponent("dictation-log.backup.json")
        )
        if let loaded = try? store.load() { log = loaded.value }
    }

    func record(text: String, outcome: DictationLogEntry.Outcome) {
        log = log.adding(DictationLogEntry(id: UUID(), date: Date(), text: text, outcome: outcome))
        try? store.save(log)
    }

    func clear() {
        log = log.cleared()
        try? store.save(log)
    }
}
