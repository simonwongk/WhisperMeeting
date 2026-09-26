import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F433 follow-up (review item 7) — a BEHAVIOURAL red/green pair, not a compile-time one. This file
// deliberately touches only surface that existed before F433's fix (`persistCount`, `editNotes`,
// `flushPendingEdits`, and a rival-writer helper in the `MeetingStoreGenerationTests`/
// `WriteConflictRecoveryTests` shape), so it compiles and RUNS against the pre-fix
// `MeetingStore.swift` too — proving the retry storm by counting real write attempts, rather than
// by a missing symbol.

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WriteConflictRetryBound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(_ title: String, id: UUID = UUID()) -> MeetingRecord {
    MeetingRecord(id: id, title: title, recordingPath: "none", status: .recorded)
}

/// A rival writer over the same files, committing a full F190 generation. Duplicated locally
/// (matches `WriteConflictRecoveryTests.foreignWriterCommits`) so this file stays self-contained
/// and compiles unmodified against a MeetingStore.swift from before F433's fix.
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

@Test("Three more flush attempts after a lost race do not re-persist — the retry storm is bounded to one attempt (F433)")
@MainActor
func lostRaceBoundsRetriesToOneAttempt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting("base", id: id))

    // A large debounce so only the explicit `flushPendingEdits()` calls below ever write.
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    try foreignWriterCommits(["rival wins"], in: root)
    store.editNotes(id: id, text: "one more edit")
    let attemptsBefore = store.persistCount

    // The first debounce cycle firing, as it would in production — and loses the race.
    store.flushPendingEdits()
    // Three more debounce cycles firing, exactly as an unattended app would produce them over the
    // next 1.5 seconds. Pre-fix, each of these is a full write attempt (`attemptsBefore + 4` in
    // total); post-fix, none of them is (`attemptsBefore + 1`).
    store.flushPendingEdits()
    store.flushPendingEdits()
    store.flushPendingEdits()

    #expect(
        store.persistCount == attemptsBefore + 1,
        "expected exactly one write attempt total, not a retry every flush"
    )
}
