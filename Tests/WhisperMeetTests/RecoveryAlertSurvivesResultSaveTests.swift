import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F884 — a result whose save lost re-saved over what the recovery had just said.
//
// F662 (`MeetingStore.saveResult`): on a lost race the result is taken out, the library re-read through
// `beginConflictRecovery`, and the result made again to the copy the re-read found and saved once more.
// When that recovery had nothing left to ask it said what happened in the alert instead — the other copy's
// commit, a meeting back in the list, a note — and the re-save's success then set the message to its own
// resting value, nothing: a banner that resolved itself went away with nothing said. Found by the round-2
// review of Wave 4 lane Q; this is its probe.

@MainActor
private func libraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F884-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Another copy of the app reading what is on disk and committing `change` of it.
@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

@MainActor
private func onDisk(_ root: URL, _ id: UUID) -> MeetingRecord? {
    MeetingStore(rootDirectory: root).meeting(id: id)
}

private let finished = "We agreed to ship on Friday."

/// A delete whose folder could not be removed, and whose save putting the row back lost twice, leaves a
/// banner holding only that row and the folder note. The other copy then saves again, and a transcript
/// finishes: its save loses, the recovery folds the banner — nothing is left to ask, so it says what
/// happened in the alert, the row back in the list included — and the transcript's re-save succeeds.
@MainActor
@Test("A result re-saved after a recovery keeps what the recovery said (F884)")
func aResultReSavedAfterARecoveryKeepsWhatTheRecoverySaid() throws {
    let root = try libraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stubborn = UUID(), review = UUID()
    let folder = root.appendingPathComponent("Recordings/\(stubborn.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: stubborn, title: "Stubborn", recordingPath: "Recordings/\(stubborn.uuidString)/meeting.wav", status: .recorded))
    store.upsert(MeetingRecord(id: review, title: "Review", status: .processing))
    // The folder refuses to go, and the other copy saves before the row's restoring save and again before
    // the recovery's save of it.
    store.removeRecordingDirectory = { _ in
        try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's first", status: .recorded)] }
        throw CocoaError(.fileWriteNoPermission)
    }
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 3 { try? otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's second", status: .recorded)] } }
    }
    #expect(store.delete(ids: [stubborn]).isEmpty)
    store.beforeIndexSaveForTesting = nil
    let held = try #require(store.conflictOffer, "fixture: the kept row's saves lost twice, so the banner holds it")
    try #require(held.unsavedNew.contains { $0.id == stubborn })
    store.clearStorageError()
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's third", status: .recorded)] }

    store.update(id: review, as: .result) { $0.transcriptText = finished; $0.status = .completed }

    #expect(store.conflictOffer == nil, "nothing is left to ask")
    #expect(onDisk(root, review)?.transcriptText == finished)
    #expect(onDisk(root, stubborn) != nil, "the kept row was not saved")
    let said = try #require(store.storageErrorMessage, "the banner went away and nothing was said")
    #expect(said.contains("“Stubborn” is in your list again."), "\(said)")
    #expect(said.contains("could not have their recordings removed"), "\(said)")
}
