import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F905 — the dictation history with two copies of the app open (F864's shape, for `dictation-log.json`).
//
// `DictationLogStore.init` left its token nil when the load found no file, so its first save was
// unchecked and replaced another copy's first save; and a save that lost a race only set
// `saveErrorMessage`, so the token stayed stale and every later dictation failed the same
// compare-and-swap until a relaunch, with the entries living only in memory. The first save now
// expects no file (`GenerationToken.absent`), and a lost race re-reads the log and makes the change
// again on what the other copy saved (`MeetingStore.commitListChange`'s shape, F663).

private func libraryRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F905-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// What a fresh load of the history finds on disk, newest first.
@MainActor
private func onDisk(_ root: URL) -> [String] {
    DictationLogStore(directory: root).log.entries.map(\.text)
}

@MainActor
@Test("A fresh library's first dictation history save does not replace another copy's first save (F905, F864)")
func aFreshLibrarysFirstDictationSaveIsChecked() throws {
    let root = try libraryRoot("fresh")
    defer { try? FileManager.default.removeItem(at: root) }
    let here = DictationLogStore(directory: root)
    let there = DictationLogStore(directory: root)
    try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("dictation-log.json").path))

    there.record(text: "theirs", outcome: .pasted)
    try #require(there.saveErrorMessage == nil)
    here.record(text: "ours", outcome: .pasted)

    #expect(here.saveErrorMessage == nil, "\(here.saveErrorMessage ?? "")")
    let saved = onDisk(root)
    #expect(saved.contains("theirs"), "the other copy's first save was replaced: \(saved)")
    #expect(saved.contains("ours"), "this copy's dictation was not saved: \(saved)")
    #expect(here.log.entries.map(\.text).contains("theirs"), "this copy did not re-read what the other saved")
}

@MainActor
@Test("A dictation whose save loses to another copy is saved onto what that copy wrote, and the next one saves too (F905)")
func aLostDictationSaveReReadsAndSavesAgain() throws {
    let root = try libraryRoot("race")
    defer { try? FileManager.default.removeItem(at: root) }
    let here = DictationLogStore(directory: root)
    here.record(text: "first", outcome: .pasted)
    try #require(here.saveErrorMessage == nil)
    // Another copy opens the history as saved, and saves after this one's last read.
    let there = DictationLogStore(directory: root)
    there.record(text: "theirs", outcome: .pasted)
    try #require(there.saveErrorMessage == nil)

    here.record(text: "ours", outcome: .pasted)

    #expect(here.saveErrorMessage == nil, "\(here.saveErrorMessage ?? "")")
    let afterOne = onDisk(root)
    #expect(afterOne.contains("theirs") && afterOne.contains("ours") && afterOne.contains("first"), "\(afterOne)")

    here.record(text: "ours again", outcome: .pasted)

    #expect(here.saveErrorMessage == nil, "the token stayed stale after a lost race: \(here.saveErrorMessage ?? "")")
    let afterTwo = onDisk(root)
    #expect(afterTwo.contains("ours again"), "the dictation after a lost race lives only in memory: \(afterTwo)")
    #expect(afterTwo.count == 4, "\(afterTwo)")
}

/// Clear All is not made again over a history the other copy has just added to: the person has not
/// seen that dictation, so the erase is theirs to ask for again (F456's rule, a failure defers). What
/// changes with F905 is that the lost race leaves the token fresh, so asking again works — before,
/// every Clear All after a lost race failed the same way until a relaunch.
@MainActor
@Test("Clear All that loses to another copy shows what that copy saved, and the next Clear All works (F905, F456)")
func aLostClearShowsWhatTheOtherCopySavedAndTheNextClearWorks() throws {
    let root = try libraryRoot("clear")
    defer { try? FileManager.default.removeItem(at: root) }
    let here = DictationLogStore(directory: root)
    here.record(text: "first", outcome: .pasted)
    let there = DictationLogStore(directory: root)
    there.record(text: "theirs", outcome: .pasted)
    try #require(there.saveErrorMessage == nil)

    let cleared = here.clear()

    #expect(!cleared, "a Clear All that lost a race was reported as done")
    #expect(here.historyEraseFailureMessage != nil)
    #expect(here.log.entries.map(\.text) == ["theirs", "first"], "the history does not show what the other copy saved: \(here.log.entries.map(\.text))")
    #expect(onDisk(root) == ["theirs", "first"], "\(onDisk(root))")

    let clearedAgain = here.clear()

    #expect(clearedAgain, "the token stayed stale after the lost race: \(here.saveErrorMessage ?? "") \(here.historyEraseFailureMessage ?? "")")
    #expect(here.saveErrorMessage == nil)
    #expect(here.historyEraseFailureMessage == nil)
    #expect(onDisk(root).isEmpty, "\(onDisk(root))")
    #expect(here.log.entries.isEmpty)
}

/// F988 — the Wave 7 review's probe P2. A dictation whose save failed for an ordinary reason (here a
/// folder that cannot be written for one save) waits in memory; the next dictation then loses a race
/// to another copy, and its re-read replaced the whole log with what is on disk and made only ITS
/// change again — so the waiting dictation vanished. Every dictation still waiting is carried over.
@MainActor
@Test("A dictation still waiting in memory survives the next lost race's re-read (F988)")
func aWaitingDictationSurvivesTheNextLostRace() throws {
    let root = try libraryRoot("waiting")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let here = DictationLogStore(directory: root)
    here.record(text: "first", outcome: .pasted)
    try #require(here.saveErrorMessage == nil)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    here.record(text: "unsaved", outcome: .pasted)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    try #require(here.saveErrorMessage != nil, "the read-only folder did not fail the save, so nothing waited in memory")
    try #require(onDisk(root) == ["first"], "\(onDisk(root))")

    let there = DictationLogStore(directory: root)
    there.record(text: "theirs", outcome: .pasted)
    try #require(there.saveErrorMessage == nil)

    here.record(text: "next", outcome: .pasted)

    #expect(here.saveErrorMessage == nil, "\(here.saveErrorMessage ?? "")")
    let saved = onDisk(root)
    #expect(Set(saved) == ["first", "unsaved", "theirs", "next"], "the waiting dictation was dropped by the re-read: \(saved)")
    #expect(saved.count == 4, "\(saved)")
    #expect(Set(here.log.entries.map(\.text)) == Set(saved), "\(here.log.entries.map(\.text))")

    // Once saved, it is no longer carried: the other copy's Clear All is not undone by this copy's
    // next dictation re-adding entries it already saved.
    let clearer = DictationLogStore(directory: root)
    #expect(clearer.clear())
    here.record(text: "after the clear", outcome: .pasted)
    #expect(onDisk(root) == ["after the clear"], "a saved dictation was carried back over the other copy's Clear All: \(onDisk(root))")
}

/// The Wave 8 lane C review's finding 7: the waiting dictation is written by the NEXT dictation's
/// first-try save (no race), so that save — not only the lost race's retry — must stop carrying it.
/// Otherwise the next lost race brings it back over another copy's Clear All.
@MainActor
@Test("A waiting dictation saved by the next dictation's first try is not carried back over a Clear All (F988)")
func aWaitingDictationSavedOnTheFirstTryIsNotCarriedBack() throws {
    let root = try libraryRoot("first-try")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let here = DictationLogStore(directory: root)
    here.record(text: "first", outcome: .pasted)
    try #require(here.saveErrorMessage == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    here.record(text: "unsaved", outcome: .pasted)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    try #require(here.saveErrorMessage != nil)
    here.record(text: "second", outcome: .pasted) // lands first try, writing "unsaved" too
    try #require(here.saveErrorMessage == nil)
    try #require(Set(onDisk(root)) == ["first", "unsaved", "second"])

    let clearer = DictationLogStore(directory: root)
    try #require(clearer.clear())
    here.record(text: "after the clear", outcome: .pasted)
    #expect(onDisk(root) == ["after the clear"], "\(onDisk(root))")
}
