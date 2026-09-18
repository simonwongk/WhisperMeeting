import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F300 — when the vocabulary exceeds the recognizer's prompt budget, which terms survived was
// collation order: the alphabetically-last were dropped, silently. Decided 2026-09-18 under the
// user's delegation: a starred subset ("sent first"), the favourites shape every list app has —
// not a drag order, which asks the user to rank a hundred terms to protect five. Stars live in a
// side file, so `vocabulary.json` keeps the format every shipped build reads.

@MainActor
private func makeStore(_ label: String) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabPriority-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MeetingStore(rootDirectory: root), root)
}

/// Enough long terms that the budget binds: the a-terms fill it, so "Zyxel…" is trimmed.
private let filler = (0..<120).map { "alphabetical filler term number \($0)" }

@MainActor
@Test("With no stars the prompt is exactly what it was: collation order (F300)")
func noStarsIsTodaysBehaviour() throws {
    let (store, root) = try makeStore("none")
    defer { try? FileManager.default.removeItem(at: root) }
    store.addVocabulary(filler + ["Zyxel Kestrel"])
    #expect(store.prioritizedVocabulary.isEmpty)
    #expect(!VocabularyPrompt.promptedTerms(store.promptVocabulary).contains("Zyxel Kestrel"))
}

@MainActor
@Test("A starred term is sent first, so the budget trims something else (F300)")
func starredTermSurvivesTheTrim() throws {
    let (store, root) = try makeStore("star")
    defer { try? FileManager.default.removeItem(at: root) }
    store.addVocabulary(filler + ["Zyxel Kestrel"])

    store.setVocabularyPriority("Zyxel Kestrel", prioritized: true)

    #expect(store.promptVocabulary.first == "Zyxel Kestrel")
    #expect(VocabularyPrompt.promptedTerms(store.promptVocabulary).contains("Zyxel Kestrel"))
    // The stored list is untouched: stars reorder the prompt, not the library.
    #expect(store.vocabulary == store.vocabulary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
}

@MainActor
@Test("Stars survive a relaunch and leave vocabulary.json in its old format (F300)")
func starsPersistBesideTheVocabulary() throws {
    let (store, root) = try makeStore("persist")
    defer { try? FileManager.default.removeItem(at: root) }
    store.addVocabulary(["Kestrel", "Osprey"])
    store.setVocabularyPriority("Osprey", prioritized: true)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.prioritizedVocabulary == ["Osprey"])
    let raw = try Data(contentsOf: root.appendingPathComponent("vocabulary.json"))
    #expect(try JSONDecoder().decode([String].self, from: raw) == ["Kestrel", "Osprey"])
}

@MainActor
@Test("Removing a term removes its star; unstarring restores the old order (F300)")
func starsFollowTheirTerms() throws {
    let (store, root) = try makeStore("follow")
    defer { try? FileManager.default.removeItem(at: root) }
    store.addVocabulary(["Kestrel", "Osprey"])
    store.setVocabularyPriority("Osprey", prioritized: true)
    store.setVocabularyPriority("Not a term", prioritized: true)
    #expect(store.prioritizedVocabulary == ["Osprey"], "only a real term can be starred")

    store.setVocabularyPriority("Osprey", prioritized: false)
    #expect(store.promptVocabulary == ["Kestrel", "Osprey"])

    store.setVocabularyPriority("Osprey", prioritized: true)
    store.removeVocabulary("Osprey")
    #expect(store.prioritizedVocabulary.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("vocabulary.priority.json").path))
}
