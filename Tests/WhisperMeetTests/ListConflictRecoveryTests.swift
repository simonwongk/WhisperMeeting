import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F663 — the vocabulary and replacement-rule lists had F433's original defect of their own. A save
// that lost to another copy of the app set the meeting index's `writeConflict`/`unsavedChanges` and
// the generic "could not be saved" alert, and never refreshed the list's token or re-read it, so with
// two copies open every later edit to that list failed the same compare-and-swap until a relaunch.
// And `addVocabulary`/`addReplacementRule` never asked whether the save landed (lane G's F-c), so the
// screen said "Saved 1 term." and cleared the rule fields over a change that was not on disk.
//
// A lost race now re-reads that list alone, applies the one change again to what the other copy
// saved, and saves once more. Each test runs two `BackupJSONStore` writers over one temp root.

@MainActor
private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F663-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Another copy of the app reading `name`.json and committing `change` of it.
@MainActor
private func otherCopyCommits<Value: Codable & Sendable>(
    _ name: String, as _: Value.Type, in root: URL, _ change: (Value?) -> Value
) throws {
    let rival = BackupJSONStore<Value>(
        primaryURL: root.appendingPathComponent("\(name).json"),
        backupURL: root.appendingPathComponent("\(name).backup.json"),
        writer: "ffff9999"
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value), expecting: seen?.token)
}

@MainActor
@Test("A vocabulary add that loses to another copy re-reads the list, adds the term to it, and the next add saves (F663)")
func lostVocabularyAddIsReappliedToTheOtherCopysList() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(["Kubernetes"])
    try otherCopyCommits("vocabulary", as: [String].self, in: root) { ($0 ?? []) + ["Grafana"] }

    let result = store.addVocabulary(["Prometheus"])

    #expect(result.added == 1)
    let expected: [String] = ["Grafana", "Kubernetes", "Prometheus"]
    #expect(MeetingStore(rootDirectory: root).vocabulary == expected, "the add did not reach disk, or lost the other copy's term")
    #expect(store.vocabulary == expected)
    #expect(store.storageErrorMessage == nil, "a race that was recovered still raised the alert")
    #expect(store.writeConflict == nil, "a list's race was reported on the meeting index's channel")
    #expect(!store.unsavedChanges, "a list's race marked the meeting index unsaved")

    store.addVocabulary(["Terraform"])
    #expect(MeetingStore(rootDirectory: root).vocabulary.contains("Terraform"), "the next add failed the same compare-and-swap")
}

@MainActor
@Test("A vocabulary removal that loses to another copy is applied to the other copy's list (F663)")
func lostVocabularyRemovalIsReapplied() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(["Kubernetes", "Grafana"])
    try otherCopyCommits("vocabulary", as: [String].self, in: root) { ($0 ?? []) + ["Prometheus"] }

    store.removeVocabulary("Kubernetes")

    let expected: [String] = ["Grafana", "Prometheus"]
    #expect(MeetingStore(rootDirectory: root).vocabulary == expected)
    #expect(store.vocabulary == expected)
    #expect(store.storageErrorMessage == nil)
}

@MainActor
@Test("A replacement rule that loses to another copy is added to the other copy's rules, and the next one saves (F663)")
func lostReplacementRuleIsReappliedToTheOtherCopysRules() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let theirs = ReplacementRule(heard: "graph on a", preferred: "Grafana")
    store.addReplacementRule(heard: "cube", preferred: "Kube")
    try otherCopyCommits("replacement-rules", as: [ReplacementRule].self, in: root) { ($0 ?? []) + [theirs] }

    let outcome = store.addReplacementRule(heard: "prom eth eus", preferred: "Prometheus")

    #expect(outcome == .added)
    let onDisk = MeetingStore(rootDirectory: root).replacementRules
    #expect(onDisk.contains(theirs), "the other copy's rule was overwritten")
    #expect(onDisk.contains(ReplacementRule(heard: "prom eth eus", preferred: "Prometheus")), "the rule did not reach disk")
    #expect(store.storageErrorMessage == nil)
    #expect(store.writeConflict == nil, "a list's race was reported on the meeting index's channel")

    store.addReplacementRule(heard: "terra form", preferred: "Terraform")
    #expect(MeetingStore(rootDirectory: root).replacementRules.contains(ReplacementRule(heard: "terra form", preferred: "Terraform")))
}

/// The second try is the last: if the other copy saves the list again before it lands, the change is
/// said to be unsaved, the list is re-read so the next edit is compared against what is on disk, and
/// nothing loops. (`beforeIndexSaveForTesting` puts that commit inside the one call.)
@MainActor
@Test("A list change that loses twice is said, not saved, and the next change still saves (F663)")
func listChangeThatLosesTwiceIsSaidAndTheNextSaves() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(["Kubernetes"])
    try otherCopyCommits("vocabulary", as: [String].self, in: root) { ($0 ?? []) + ["Grafana"] }
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 { try? otherCopyCommits("vocabulary", as: [String].self, in: root) { ($0 ?? []) + ["Loki"] } }
    }

    let result = store.addVocabulary(["Prometheus"])

    store.beforeIndexSaveForTesting = nil
    #expect(saves == 2, "the change was tried more than twice")
    #expect(result.wasRefused, "the Add box was told the term was saved")
    let onDisk: [String] = ["Grafana", "Kubernetes", "Loki"]
    #expect(MeetingStore(rootDirectory: root).vocabulary == onDisk)
    #expect(store.vocabulary == onDisk, "the list does not show what is on disk")
    let message = try #require(store.storageErrorMessage, "nothing said the change was not saved")
    #expect(message.contains("make the change again"), "\(message)")
    #expect(store.writeConflict == nil)

    store.addVocabulary(["Prometheus"])
    #expect(MeetingStore(rootDirectory: root).vocabulary.contains("Prometheus"), "the token was left stale")
}

/// Lane G's F-c: when the save does not land at all, the Add box and the rule editor were told it
/// did. The list is put back to what is on disk, so the screen and the file agree, and the caller is
/// told nothing was saved — the Add box keeps the typing, the rule editor keeps its fields.
@MainActor
@Test("An add whose save fails says it was not saved, and the list shows what is on disk (F663)")
func failedListSaveIsNotReportedAsSaved() throws {
    let root = try makeRoot()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(["Kubernetes"])
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    try #require(!FileManager.default.isWritableFile(atPath: root.path),
                 "precondition: this process cannot write a 0555 folder (it would if it ran as root)")

    let result = store.addVocabulary(["Prometheus"])
    let rule = store.addReplacementRule(heard: "cube", preferred: "Kube")

    #expect(!result.message().contains("Saved"), "the Add box said a term was saved: \(result.message())")
    #expect(store.vocabulary == ["Kubernetes"], "the list shows a term that is not on disk")
    #expect(rule != .added, "the rule editor was told the rule was added")
    #expect(store.replacementRules.isEmpty, "the rules show a rule that is not on disk")
    #expect(store.storageErrorMessage != nil, "nothing said why")
    #expect(store.writeConflict == nil, "a list's failure was reported on the meeting index's channel")
}
