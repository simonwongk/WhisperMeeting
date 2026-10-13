import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F933 — a missing `vocabulary.json` or `replacement-rules.json` whose backup reads.
//
// `BackupJSONStore.load` opens the backup for a missing primary as for a damaged one, and since F844
// says which it was (`StoreRepair.primaryMissing`). The lists' notice did not look: it said the file
// "was damaged … The damaged file has not been changed, and is copied aside before anything replaces
// it" — about a file that does not exist. F844's shape for the meeting index, applied to the lists:
// the store keeps what the load found beside the list's health, and every sentence takes it.

private func libraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F933-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A library whose two lists each have one saved entry, so each has a primary and a backup.
@MainActor
private func libraryWithSavedLists() throws -> URL {
    let root = try libraryRoot()
    let store = MeetingStore(rootDirectory: root)
    _ = store.addVocabulary(["Kubernetes"])
    _ = store.addReplacementRule(heard: "cube CTL", preferred: "kubectl")
    for name in ["vocabulary.json", "vocabulary.backup.json", "replacement-rules.json", "replacement-rules.backup.json"] {
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "fixture: \(name) was not written")
    }
    return root
}

@MainActor
@Test("A missing list file opened from its backup is called missing, not damaged (F933)",
      arguments: [MeetingStore.EditableList.vocabulary, .replacementRules])
func aMissingListFileIsNotCalledDamaged(list: MeetingStore.EditableList) throws {
    let root = try libraryWithSavedLists()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = list == .vocabulary ? "vocabulary.json" : "replacement-rules.json"
    try FileManager.default.removeItem(at: root.appendingPathComponent(file))

    let store = MeetingStore(rootDirectory: root)

    try #require(store.health(of: list) == .recoveredFromBackup, "fixture: the backup was not opened (\(store.health(of: list)))")
    #expect(store.fileOnDisk(of: list) == .missing)
    let notice = try #require(store.damagedListNotice(for: list))
    #expect(notice.contains("\(file) is missing"), "\(notice)")
    #expect(!notice.contains("damaged"), "\(notice)")
    #expect(!notice.contains("copied aside before"), "\(notice)")
    #expect(notice.contains("Nothing was copied aside, and nothing has been changed."), "\(notice)")
    #expect(notice.contains(store.keepLoadedListTitle(for: list)), "the way out is not named: \(notice)")
    #expect(store.startupRecoveryMessages.contains(notice), "the launch alert says something else: \(store.startupRecoveryMessages)")
    // The list on screen is the backup's: what Keep saves as the current copy.
    switch list {
    case .vocabulary: #expect(store.vocabulary == ["Kubernetes"])
    case .replacementRules: #expect(store.replacementRules.map(\.preferred) == ["kubectl"])
    }

    // A refused edit says the same thing, not "could not be read cleanly".
    switch list {
    case .vocabulary: _ = store.addVocabulary(["Grafana"])
    case .replacementRules: _ = store.addReplacementRule(heard: "graph Anna", preferred: "Grafana")
    }
    let refused = try #require(store.storageErrorMessage)
    #expect(refused.contains("\(file) is missing"), "\(refused)")
    #expect(!refused.contains("could not be read cleanly"), "\(refused)")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), "a refused edit wrote the file")
}

@MainActor
@Test("A damaged list file is still called damaged, and what was on disk is forgotten with the health (F933)")
func aDamagedListFileIsStillCalledDamagedAndKeepResetsWhatWasOnDisk() throws {
    let root = try libraryWithSavedLists()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{ not a list".utf8).write(to: root.appendingPathComponent("vocabulary.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("replacement-rules.json"))

    let store = MeetingStore(rootDirectory: root)

    try #require(store.health(of: .vocabulary) == .recoveredFromBackup)
    #expect(store.fileOnDisk(of: .vocabulary) == .asHealthSays)
    let damaged = try #require(store.damagedListNotice(for: .vocabulary))
    #expect(damaged.contains("vocabulary.json was damaged"), "\(damaged)")
    #expect(!damaged.contains("missing"), "\(damaged)")

    try #require(store.fileOnDisk(of: .replacementRules) == .missing)
    store.keepLoadedList(.replacementRules)
    #expect(store.health(of: .replacementRules) == .complete)
    #expect(store.fileOnDisk(of: .replacementRules) == .asHealthSays, "what was on disk outlived the health it came with")
    #expect(store.damagedListNotice(for: .replacementRules) == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement-rules.json").path), "Keep did not write the file")
}
