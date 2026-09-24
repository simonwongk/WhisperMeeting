import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F193 — a damaged library must have a way out, and the way out has to actually work.
//
// F190 built the hard half: `MeetingStore.indexGenerations()` lists the retained generations and
// `restoreIndexGeneration(_:)` brings one back, documented as "the one mutator that works while the
// library is read-only" precisely so this ticket's dead end could be closed.
//
// What was never checked is whether restoring makes the library WRITABLE again, which is what F193's
// verification actually asks for. It did not: `health` is only ever assigned through `degrade(to:)`,
// which by design refuses to improve (MeetingStore.swift), so a successful restore brought the data
// back and left every mutator still refusing. The user would have gone through a recovery flow and
// still been unable to rename a meeting.
//
// The monotonic `degrade` is load-bearing and stays. Three persisted stores share ONE health value,
// and its comment explains why a plain assignment is wrong: "a perfectly readable vocabulary.json
// loading after a corrupt meetings.json puts .complete back and silently re-opens every mutator on a
// library that cannot be read". So recovery must not set health directly — it re-evaluates all three
// stores from scratch, exactly as `init` does, and lets each degrade the shared value again. A store
// that is still broken stays read-only.

/// A degraded store that still holds a real record, real audio, and a retained generation to restore.
///
/// Mirrors `makeBackupRecoveredStore` in `DegradedLibraryTests.swift`: the seed store is `.complete`,
/// so its `upsert` both persists and retains a generation; corrupting ONLY the primary makes the
/// reopened store load from the backup, so it is non-empty and read-only — the degraded state a
/// truncated primary write actually produces in the field.
@MainActor
private func makeRecoverableStore() throws -> (store: MeetingStore, root: URL, meeting: MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))

    let meeting = MeetingRecord(
        id: id,
        title: "Quarterly review",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: "the original transcript"
    )
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting)
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")

    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    return (MeetingStore(rootDirectory: root), root, meeting)
}

@Test("A degraded library lists the generations it could restore")
@MainActor
func degradedLibraryListsItsGenerations() throws {
    let (store, root, _) = try makeRecoverableStore()
    defer { try? FileManager.default.removeItem(at: root) }

    try #require(store.isDegraded, "the fixture must be read-only, or there is nothing to recover from")
    // Reading and reporting is allowed while degraded — it changes nothing.
    #expect(try !store.indexGenerations().isEmpty)
}

@Test("Restoring a generation returns a degraded library to a writable state")
@MainActor
func restoringAGenerationMakesTheLibraryWritableAgain() throws {
    let (store, root, meeting) = try makeRecoverableStore()
    defer { try? FileManager.default.removeItem(at: root) }

    try #require(store.isDegraded)
    let generation = try #require(try store.indexGenerations().first)

    try store.restoreIndexGeneration(generation)

    // The data came back...
    #expect(store.meetings.map(\.id) == [meeting.id])
    // ...and so did the ability to change it. This is the assertion F193 was filed for.
    #expect(!store.isDegraded)
    #expect(store.health == .complete)

    // Prove it for real, not just via the flag: a mutation must now persist.
    store.update(id: meeting.id) { $0.title = "Renamed after recovery" }
    #expect(store.meeting(id: meeting.id)?.title == "Renamed after recovery")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: meeting.id)?.title == "Renamed after recovery")
    #expect(!reopened.isDegraded)
}

@Test("Recovery never removes audio")
@MainActor
func recoveryPreservesAudio() throws {
    let (store, root, meeting) = try makeRecoverableStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent(meeting.recordingPath)
    try #require(FileManager.default.fileExists(atPath: audio.path))

    let generation = try #require(try store.indexGenerations().first)
    try store.restoreIndexGeneration(generation)

    // F193: "must never run automatically, never delete audio, and must preserve the quarantined
    // bytes". Audio is never touched by an index restore, and this pins it.
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(try Data(contentsOf: audio) == Data("audio".utf8))
}

@Test("A store that is still broken after a restore stays read-only")
@MainActor
func revalidationDoesNotWhitewashAStillBrokenLibrary() throws {
    // `_` for the store: this test reopens the library below rather than using the first handle,
    // and an unused binding is a warning CI prints on every run. Noise in that log is not free —
    // it is what a `grep` for `error:` scrolls past.
    let (_, root, _) = try makeRecoverableStore()
    defer { try? FileManager.default.removeItem(at: root) }

    // Break a DIFFERENT store in the same library. `vocabulary.json` and its backup are unreadable,
    // so re-evaluating health after the index restore must still find this and refuse its edits —
    // recovery recomputes health rather than only ever worsening it, and must not whitewash a
    // store it did not repair.
    //
    // Since F464 that refusal is the vocabulary's alone. This used to assert the whole library
    // stayed read-only, which was the defect: the meeting index came back and the user still
    // could not record, with nothing left in Recover Library that could help.
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("vocabulary.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("vocabulary.backup.json"))

    let reopened = MeetingStore(rootDirectory: root)
    try #require(reopened.isDegraded)
    let generation = try #require(try reopened.indexGenerations().first)
    try reopened.restoreIndexGeneration(generation)

    #expect(reopened.isListReadOnly(.vocabulary), "the restore must not whitewash an unreadable vocabulary")
    #expect(reopened.health(of: .vocabulary) != .complete)
    #expect(!reopened.isDegraded, "the meeting index it did restore is writable again")
}

// MARK: - F193's surface: the strings a user chooses a generation from

@Test("A generation is described by what distinguishes it, not by its fingerprint")
func generationLabelIsADecisionAid() {
    // A user picking which copy of their library to go back to is choosing from this string alone.
    // A fingerprint is not a decision aid; a record count and a date are.
    let label = AppModel.generationLabel(RetainedGeneration(
        name: "g-000000007-abc123.json",
        sequence: 7,
        fingerprint: "abc123",
        byteCount: 4_096,
        wroteAtEpochSeconds: 1_757_000_000,
        recordCount: 17,
        bytesMatchName: true
    ))
    #expect(label.contains("17 meetings"))
    #expect(!label.contains("abc123"))
    #expect(label.contains("·"))
}

@Test("A single-meeting generation is not described as '1 meetings'")
func generationLabelSingularises() {
    let label = AppModel.generationLabel(RetainedGeneration(
        name: "g-000000001-x.json", sequence: 1, fingerprint: "x", byteCount: 10,
        wroteAtEpochSeconds: nil, recordCount: 1, bytesMatchName: true
    ))
    #expect(label.contains("1 meeting"))
    #expect(!label.contains("1 meetings"))
}

@Test("A damaged generation is labelled rather than hidden")
func damagedGenerationIsLabelled() {
    // `restoreIndexGeneration` refuses an entry whose bytes no longer fingerprint to its own name.
    // Omitting it from the list would make a real option look like a missing one, which reads as a
    // bug; saying so lets the user see why the copy they remember cannot be used.
    let label = AppModel.generationLabel(RetainedGeneration(
        name: "g-000000003-y.json", sequence: 3, fingerprint: "y", byteCount: 10,
        wroteAtEpochSeconds: 1_757_000_000, recordCount: 4, bytesMatchName: false
    ))
    #expect(label.contains("cannot be used"))
}

@Test("A generation with no metadata still gets a name to choose by")
func generationLabelFallsBackToTheName() {
    // An entry written before the record count and timestamp existed. An empty row would be
    // unpickable.
    let label = AppModel.generationLabel(RetainedGeneration(
        name: "g-000000002-z.json", sequence: 2, fingerprint: "z", byteCount: 10,
        wroteAtEpochSeconds: nil, recordCount: nil, bytesMatchName: true
    ))
    #expect(label == "g-000000002-z.json")
}
