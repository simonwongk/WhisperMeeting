import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F190 Task 10 — threading generation tokens through the store. Without this the compare-and-swap
// never fires: every save would pass `expecting: nil`, which is the compatibility default meaning
// last-writer-wins, and the whole transaction layer would sit in the tree doing nothing.
//
// The other half is the CHANNEL. A save-time race must not touch `health`, because
// `AppModel.startRecording` pre-flights `!store.isDegraded` and relies on that answer for the whole
// recording — a mid-session degrade would make `stopRecording`'s `upsert` silently return and lose a
// finished meeting. So a conflict goes to `writeConflict`/`unsavedChanges` and health stays put.
//
// Genuinely red without the fix: there is no `writeConflict`, no `unsavedChanges`, no
// `persistCommitCount`, and no token is threaded anywhere.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingStoreGeneration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(_ title: String) -> MeetingRecord {
    MeetingRecord(id: UUID(), title: title, recordingPath: "none", status: .recorded)
}

/// A rival writer over the same files, committing a full F190 generation — an old bundle, a second
/// app instance, or a hand-restore that went through the store.
@MainActor
private func foreignWriterCommits(_ titles: [String], in root: URL) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let existing = try rival.load()
    _ = try rival.save(titles.map { meeting($0) }, expecting: existing?.token)
}

@Test("A successful save refreshes the token, so consecutive saves keep working (F190)")
@MainActor
func aSuccessfulSaveRefreshesTheToken() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    // If the token were seeded once and never refreshed, the SECOND save would carry a token
    // describing the first generation and conflict with its own predecessor.
    store.upsert(meeting("one"))
    #expect(store.storageErrorMessage == nil)
    store.upsert(meeting("two"))
    store.upsert(meeting("three"))

    #expect(store.storageErrorMessage == nil, "a store conflicted with its own previous save")
    #expect(store.writeConflict == nil)
    #expect(!store.unsavedChanges)
    #expect(store.meetings.count == 3)
    #expect(store.persistCommitCount == 3)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meetings.count == 3)
    #expect(reopened.health == .complete)
}

@Test("A rival writer's commit is refused, reported, and the refused body is preserved (F190)")
@MainActor
func aRivalCommitIsRefusedAndTheBodyPreserved() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("shared base"))

    // A fresh store, holding the token for the generation it just read.
    let store = MeetingStore(rootDirectory: root)
    #expect(store.health == .complete)
    let attemptedBefore = store.persistCount
    let committedBefore = store.persistCommitCount

    try foreignWriterCommits(["the rival's library"], in: root)

    store.upsert(meeting("our edit"))

    // Refused, and SAID SO. Today the most destructive save failure in the app produces no
    // user-visible message at all.
    #expect(store.writeConflict != nil, "a lost race was not reported to the user")
    #expect(store.unsavedChanges, "the user's unsaved edit was not flagged")
    #expect(store.storageErrorMessage != nil)

    // Health is UNTOUCHED. This is the load-bearing part: a mid-session degrade would make
    // `stopRecording`'s upsert silently return and lose a finished meeting.
    #expect(store.health == .complete)
    #expect(!store.isDegraded)

    // "Attempted" still counts the attempt; only commits count the commit.
    #expect(store.persistCount == attemptedBefore + 1)
    #expect(store.persistCommitCount == committedBefore)

    // Neither update is lost: the rival's generation is live, and our body is on disk as a branch.
    let live = try #require(
        try BackupJSONStore<[MeetingRecord]>(
            primaryURL: root.appendingPathComponent("meetings.json"),
            backupURL: root.appendingPathComponent("meetings.backup.json")
        ).load()
    )
    #expect(live.value.map(\.title) == ["the rival's library"])
    let branches = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("meetings.history").path
    ).filter { $0.hasPrefix("conflict-") }
    #expect(branches.count == 1, "the refused edit was discarded instead of preserved")
}

@Test("A recovered save clears the conflict report and the unsaved flag (F190)")
@MainActor
func aRecoveredSaveClearsTheConflictReport() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base"))
    let store = MeetingStore(rootDirectory: root)
    try foreignWriterCommits(["rival"], in: root)
    store.upsert(meeting("refused"))
    #expect(store.writeConflict != nil)

    // The store re-reads the library and tries again. A conflict is a transient race, not a
    // terminal state — nothing here is read-only, so the next save must be able to succeed.
    store.reloadForConflictRecovery()
    store.upsert(meeting("accepted"))

    #expect(store.writeConflict == nil, "the conflict report outlived the conflict")
    #expect(!store.unsavedChanges)
    #expect(store.storageErrorMessage == nil)
    #expect(store.meetings.contains { $0.title == "accepted" })
}

@Test("The writer lease is published as an advisory and never sets health (F190)")
@MainActor
func theWriterLeaseIsAdvisoryOnly() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = MeetingStore(rootDirectory: root)
    #expect(first.writerLease == .held(realm: "shared"))
    #expect(first.health == .complete)

    // A second store over the same root shares ONE lease rather than contending with the first.
    // `flock` attaches to the open file description, so two independent acquisitions in one process
    // would have the two stores reporting each other as rival applications.
    let second = MeetingStore(rootDirectory: root)
    #expect(second.writerLease == .held(realm: "shared"))
    #expect(second.health == .complete)
    #expect(!second.isDegraded, "the lease made a library read-only, which it must never do")

    // And it still saves.
    second.upsert(meeting("written while the lease was shared"))
    #expect(second.storageErrorMessage == nil)
}

@Test("A save failure's message is not erased by the operation that follows it (F190)")
@MainActor
func aSaveFailureMessageSurvivesTheNextStep() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base"))
    let store = MeetingStore(rootDirectory: root)
    try foreignWriterCommits(["rival"], in: root)

    // `delete` used to end with an unconditional `storageErrorMessage = nil`, so the most
    // destructive save failure in the app cleared its own explanation on the way out.
    store.upsert(meeting("will be refused"))
    let message = try #require(store.storageErrorMessage)
    #expect(store.meetings.isEmpty == false)

    // A second refused mutation must not clear it either.
    store.upsert(meeting("also refused"))
    #expect(store.storageErrorMessage != nil, "the failure explanation was cleared")
    #expect(store.storageErrorMessage?.isEmpty == false)
    _ = message
}

// F190 Task 11 — the app-level restore. This is the one call standing between "the bytes survive on
// disk" and "the user gets their library back", and it is also the only mutator in `MeetingStore`
// that must work while the library is READ-ONLY. Everything else is refused when health is not
// complete; a recovery action that were refused for the same reason would leave the exact dead end
// F193 was filed for.

@Test("The recovery list distinguishes a real generation from a wipe (F190)")
@MainActor
func theRecoveryListShowsRecordCounts() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    for index in 0..<17 { store.upsert(meeting("meeting \(index)")) }

    let generations = try store.indexGenerations()
    // "42 · 0 meetings · 3 min ago" beside "41 · 17 meetings · yesterday" is exactly the
    // discrimination the 2026-08-14 recovery failed to make.
    #expect(generations.contains { $0.recordCount == 17 })
    #expect(generations.allSatisfy { $0.bytesMatchName })
}

@Test("Restoring a generation brings the library back and is itself undoable (F190)")
@MainActor
func restoringAGenerationBringsTheLibraryBack() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    for index in 0..<17 { store.upsert(meeting("meeting \(index)")) }
    let realCount = store.meetings.count

    // The wipe: every meeting deleted, committed as a perfectly valid empty generation.
    for record in store.meetings { store.delete(id: record.id) }
    #expect(store.meetings.isEmpty)

    let target = try #require(
        try store.indexGenerations().first { $0.recordCount == realCount },
        "the 17-meeting generation is not in the recovery list"
    )
    try store.restoreIndexGeneration(target)

    #expect(store.meetings.count == realCount, "the restore did not reach memory")
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meetings.count == realCount, "the restore did not reach disk")
    #expect(reopened.health == .complete)
    // Append-only, so the empty generation is still there and the restore can be undone.
    #expect(try reopened.indexGenerations().contains { $0.recordCount == 0 })
}

@Test("A restore works on a read-only library, and what it does and does not fix (F190)")
@MainActor
func restoringWorksWhileTheLibraryIsReadOnly() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // The incident shape exactly: a real library, then a valid-but-empty index beside recording
    // folders that hold finished recordings. That is `.suspectEmpty` — degraded, every mutator
    // refused — and it is the state a user would actually be trying to recover from.
    let seed = MeetingStore(rootDirectory: root)
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    for index in 0..<3 {
        let id = UUID()
        let directory = recordings.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var wav = WAVWriter.header(sampleRate: 16_000, dataByteCount: 32_000)
        wav.append(Data(count: 32_000))
        try wav.write(to: directory.appendingPathComponent("meeting.wav"))
        seed.upsert(MeetingRecord(
            id: id, title: "meeting \(index),",
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed
        ))
    }
    let realCount = seed.meetings.count
    for record in seed.meetings { seed.update(id: record.id) { $0.title = "kept" } }
    // Wipe the index only — the recordings stay, which is what makes it suspicious.
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"), options: .atomic)
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.backup.json"), options: .atomic)

    let damaged = MeetingStore(rootDirectory: root)
    #expect(damaged.isDegraded, "expected a degraded library to recover from")
    #expect(damaged.meetings.isEmpty)
    // Ordinary mutation is refused, as F187 requires.
    damaged.upsert(meeting("should be refused"))
    #expect(damaged.meetings.isEmpty)

    // The recovery action is NOT refused. It does not trust memory at all: the bytes come off disk,
    // verified against the fingerprint in their own name and decoded before anything is installed.
    let target = try #require(
        try damaged.indexGenerations().first { $0.recordCount == realCount },
        "the real generation is not offered while degraded"
    )
    try damaged.restoreIndexGeneration(target)

    // The bytes are back on disk — the part that matters, and the part that was irrecoverable before.
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meetings.count == realCount)
    #expect(reopened.health == .complete)
    #expect(!reopened.isDegraded)

    // What it does NOT fix, pinned so it is not a surprise: `degrade(to:)` only ever worsens, and
    // one health value is shared by the meeting, vocabulary and replacement-rule stores. Clearing it
    // here could re-open mutation over a vocabulary index that is still corrupt, so this instance
    // stays read-only and the user must relaunch. Making recovery complete without a relaunch is
    // F193's job, not this mechanism's.
    #expect(damaged.isDegraded, "if this ever passes, re-read the comment above before celebrating")
}
