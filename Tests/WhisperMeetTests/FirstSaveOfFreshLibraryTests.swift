import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F864 — two copies of the app open on a library that has no `meetings.json` yet: a first launch, or
/// a library folder just emptied. Neither has read a generation, so each held no token and its first
/// save was unchecked (`expecting: nil`, last-writer-wins): the second copy to save replaced the
/// first copy's index, and the first copy's meeting was gone from the list with its audio left as an
/// orphan. Found by Wave 4 lane Q while writing `lostStopWithNothingToDecideRaisesNoBanner`.
///
/// A copy that looked and found no file now expects no file (`GenerationToken.absent`), so a file
/// that appeared meanwhile is a lost race like any other, and the F642/F667 recovery runs: re-read,
/// and a meeting only this window has is put onto the other copy's library and saved.

@MainActor
private func emptyLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F864-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("A fresh library's first save does not replace another copy's first save (F864)")
func firstIndexSaveOfAFreshLibraryIsChecked() throws {
    let root = try emptyLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    // Both copies open before either has saved anything.
    let other = MeetingStore(rootDirectory: root)
    let here = MeetingStore(rootDirectory: root)
    let theirs = MeetingRecord(title: "Recorded in the other window", status: .recorded)
    let ours = MeetingRecord(title: "Recorded here", status: .recorded)

    other.upsert(theirs, as: .result)
    here.upsert(ours, as: .result)

    #expect(
        MeetingStore(rootDirectory: root).meeting(id: theirs.id) != nil,
        "the other copy's first save was overwritten"
    )
    #expect(MeetingStore(rootDirectory: root).meeting(id: ours.id) != nil)
    #expect(here.meeting(id: theirs.id) != nil, "this window re-read the library the other copy saved")
    #expect(here.writeConflict == nil)
    #expect(!here.unsavedChanges)
    // Nothing to ask the person: this window's meeting is only this window's, so no banner and no
    // alert — it simply joins the other copy's list (F667's rule for a new meeting).
    #expect(here.conflictOffer == nil)
    #expect(here.storageErrorMessage == nil)
    // The refused first body is kept as a conflict branch (F190), not dropped.
    let history = root.appendingPathComponent("meetings.history", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? []
    #expect(names.contains { $0.hasPrefix("conflict-") })

    // And this window is not stuck: its next save is compared against what is on disk now.
    here.update(id: ours.id) { $0.title = "Recorded here, renamed" }
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: ours.id)?.title == "Recorded here, renamed")
    #expect(reopened.meeting(id: theirs.id) != nil)
}

@MainActor
@Test("A fresh library's first vocabulary save does not replace another copy's (F864)")
func firstListSaveOfAFreshLibraryIsChecked() throws {
    let root = try emptyLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = MeetingStore(rootDirectory: root)
    let here = MeetingStore(rootDirectory: root)

    _ = other.addVocabulary(["Grafana"])
    _ = here.addVocabulary(["Kubernetes"])

    let onDisk = MeetingStore(rootDirectory: root).vocabulary
    #expect(onDisk.contains("Grafana"), "the other copy's first vocabulary save was overwritten: \(onDisk)")
    #expect(onDisk.contains("Kubernetes"))
    #expect(here.vocabulary.contains("Grafana"))
}

/// The replacement rules' own line (`readReplacementRules` setting `.absent`), which the vocabulary
/// test above cannot see: the lane-V review's mutant that deleted it passed every other test (V2).
@MainActor
@Test("A fresh library's first replacement-rule save does not replace another copy's (F864)")
func firstReplacementRuleSaveOfAFreshLibraryIsChecked() throws {
    let root = try emptyLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = MeetingStore(rootDirectory: root)
    let here = MeetingStore(rootDirectory: root)
    let theirs = ReplacementRule(heard: "graph Anna", preferred: "Grafana")
    let ours = ReplacementRule(heard: "cube CTL", preferred: "kubectl")

    #expect(other.addReplacementRule(heard: theirs.heard, preferred: theirs.preferred) == .added)
    #expect(here.addReplacementRule(heard: ours.heard, preferred: ours.preferred) == .added)

    let onDisk = MeetingStore(rootDirectory: root).replacementRules
    #expect(onDisk.contains(theirs), "the other copy's first replacement-rule save was overwritten: \(onDisk)")
    #expect(onDisk.contains(ours))
    #expect(here.replacementRules.contains(theirs))
}

@MainActor
@Test("A library with no index yet still saves its first meeting (F864)")
func aLoneFreshLibraryStillSaves() throws {
    let root = try emptyLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let first = MeetingRecord(title: "First meeting", status: .recorded)

    store.upsert(first, as: .result)
    _ = store.addVocabulary(["Grafana"])
    _ = store.addReplacementRule(heard: "graph Anna", preferred: "Grafana")

    #expect(store.writeConflict == nil)
    #expect(store.storageErrorMessage == nil)
    #expect(store.persistCommitCount == 1)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: first.id) != nil)
    #expect(reopened.vocabulary == ["Grafana"])
    #expect(reopened.replacementRules == [ReplacementRule(heard: "graph Anna", preferred: "Grafana")])
}
