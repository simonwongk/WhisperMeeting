import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeVocabularyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetVocabulary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func bytes(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

@Test("Terms beyond the prompt budget stay in storage and only the prompt is capped")
@MainActor
func vocabularyStorageSurvivesThePromptCap() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetVocabulary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    let terms = (0..<150).map { "term-number-\($0)" }
    store.addVocabulary(terms)

    #expect(store.vocabulary.count == 150)
    #expect(store.promptVocabulary.count <= 100)
    #expect(store.promptVocabulary.joined(separator: ", ").count <= 1_000)

    // Reload from disk: nothing was truncated on the way out or the way back in.
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.vocabulary.count == 150)
}

// MARK: - Health may only ever get worse during construction (F187)

/// The hazard the plan's own wording would have created. `health` is ONE scalar shared by three stores
/// that all load in sequence inside `init`, and `mutationIsAllowed()` gates vocabulary, replacement-rule
/// AND meeting mutations off it. "Set `health` as in Task 4" inside `loadVocabulary` makes the
/// assignment last-writer-wins: a perfectly readable `vocabulary.json` loading after a corrupt
/// `meetings.json` overwrites `.unreadable` with `.complete` and silently re-opens every mutator on a
/// library that cannot be read — the exact F187 failure, reintroduced by one line.
@Test("A readable vocabulary index cannot un-degrade a library whose meeting index is corrupt")
@MainActor
func readableVocabularyCannotUpgradeACorruptMeetingIndex() throws {
    let root = try makeVocabularyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    // Valid, and loaded AFTER the meeting index — this is the file that would do the clobbering.
    try Data(#"["alpha","beta"]"#.utf8).write(to: root.appendingPathComponent("vocabulary.json"))

    let store = MeetingStore(rootDirectory: root)

    // It really did load, so the test is about health precedence and not about a failed read.
    try #require(store.vocabulary == ["alpha", "beta"])
    #expect(store.isDegraded)
    #expect(!store.health.allowsMutation)

    // ...and the guard those flags feed is still refusing.
    let before = store.persistCount
    store.upsert(MeetingRecord(title: "New"))
    store.addVocabulary(["gamma"])
    #expect(store.meetings.isEmpty)
    #expect(store.vocabulary == ["alpha", "beta"])
    #expect(store.persistCount == before)
    #expect(store.storageErrorMessage != nil)
}

/// The other direction of the same invariant: a vocabulary index that cannot be read at all must
/// DEGRADE an otherwise healthy library rather than start empty and writable. Left writable, the next
/// `addVocabulary` persists a one-term list over a file that held hundreds — the bytes survive in
/// quarantine, but the live library silently loses the lot (F187).
@Test("An unreadable vocabulary index degrades the library instead of starting empty and writable")
@MainActor
func unreadableVocabularyDegradesTheLibrary() throws {
    let root = try makeVocabularyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("vocabulary.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("vocabulary.backup.json"))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.isDegraded)
    #expect(store.vocabulary.isEmpty)

    store.addVocabulary(["gamma"])

    #expect(store.vocabulary.isEmpty)
    // The undecodable bytes are still exactly where they were — quarantine copies, it never moves.
    #expect(bytes(at: root.appendingPathComponent("vocabulary.json")) == "broken-primary")
    #expect(bytes(at: root.appendingPathComponent("vocabulary.backup.json")) == "broken-backup")
}

/// Task 4 deleted the silent re-persist after a backup-recovered MEETING index; `loadVocabulary` kept
/// its own copy of it. Because it runs inside `init` — right after `loadMeetings` may have declared the
/// library read-only — it wrote to disk during the store's own construction, bypassing the mutation
/// guard entirely (it calls the file store directly, not `persistVocabulary()`). `docs/RECOVERY.md`
/// already promises the damaged primary is left exactly as it is (F187).
@Test("A backup-recovered vocabulary index is read-only and is not silently re-persisted")
@MainActor
func backupRecoveredVocabularyIsReadOnlyAndNotRePersisted() throws {
    let root = try makeVocabularyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.addVocabulary(["alpha", "beta"])
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")
    let backupBefore = try #require(bytes(at: root.appendingPathComponent("vocabulary.backup.json")))

    // Corrupt ONLY the primary, so the backup decodes and `load()` returns `.recoveredFromBackup`.
    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("vocabulary.json"))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.vocabulary == ["alpha", "beta"])
    #expect(store.isDegraded)
    // Nothing was written during construction: the damaged primary is untouched and the backup is the
    // same generation it was before.
    #expect(bytes(at: root.appendingPathComponent("vocabulary.json")) == "truncated-primary")
    #expect(bytes(at: root.appendingPathComponent("vocabulary.backup.json")) == backupBefore)
}

/// The same re-persist lived in `loadReplacementRules`, for the same reason and with the same fix.
@Test("A backup-recovered replacement-rule index is read-only and is not silently re-persisted")
@MainActor
func backupRecoveredReplacementRulesAreReadOnlyAndNotRePersisted() throws {
    let root = try makeVocabularyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.addReplacementRule(heard: "kubernets", preferred: "Kubernetes")
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")
    let backupBefore = try #require(bytes(at: root.appendingPathComponent("replacement-rules.backup.json")))

    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("replacement-rules.json"))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.replacementRules.map(\.preferred) == ["Kubernetes"])
    #expect(store.isDegraded)
    #expect(bytes(at: root.appendingPathComponent("replacement-rules.json")) == "truncated-primary")
    #expect(bytes(at: root.appendingPathComponent("replacement-rules.backup.json")) == backupBefore)
}

/// `degrade(to:)` is only as safe as the ordering it consults, and that ordering lives beside the enum.
/// `.complete` must be the unique floor: if any other state ever ranked equal to it, a healthy store
/// loading last would stop being refused and the clobber above would be back.
@Test("Every damaged store health outranks .complete, so nothing can upgrade to it")
func completeIsTheUniqueLeastSevereHealth() {
    let damaged: [PersistedStoreHealth] = [
        .recoveredFromBackup,
        .partiallySalvaged(parkedIdentifiers: ["index 1"]),
        .suspectEmpty(recordingFolderCount: 3),
        .unreadable(quarantined: ["meetings.unreadable-2026.json"]),
        .unavailable("permission denied")
    ]
    for state in damaged {
        #expect(state.isWorse(than: .complete))
        #expect(!PersistedStoreHealth.complete.isWorse(than: state))
        #expect(!state.allowsMutation)
    }
}
