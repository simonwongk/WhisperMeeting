import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F751 — the launch's notes.md backfill checked the library's state once, before its detached pass,
// and never again. A library that went read-only while the pass ran kept having notes.md written under
// F187's read-only promise, and a restore that began meanwhile would have had pre-restore notes written
// into its folders. The pass now asks the live state before each meeting's file.
//
// Both cases run through the existing `notesBackfillPass` seam: the replacement runs the real pass over
// the first meeting, changes the state, then runs the real pass over the rest — so the state changes
// between two of the pass's own writes, which is the window the ticket names.

@MainActor
private func makeLibrary(_ label: String) throws -> (store: MeetingStore, root: URL, first: MeetingRecord, second: MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F751-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 999)
    var seeded: [MeetingRecord] = []
    for title in ["First meeting", "Second meeting"] {
        let id = UUID()
        let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A finished WAV, so the wipe check counts the folder as a recording.
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
            .write(to: folder.appendingPathComponent("meeting.wav"))
        let meeting = MeetingRecord(
            id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: "What was said in \(title)."
        )
        store.upsert(meeting, as: .result)
        seeded.append(meeting)
    }
    // Nothing pending and nothing on disk yet: every notes.md below is the backfill's.
    store.flushPendingNotesSidecars()
    for meeting in seeded {
        try? FileManager.default.removeItem(at: notesURL(meeting, root))
    }
    return (store, root, seeded[0], seeded[1])
}

private func notesURL(_ meeting: MeetingRecord, _ root: URL) -> URL {
    root.appendingPathComponent("Recordings/\(meeting.id.uuidString)/notes.md")
}

@Test("A library that goes read-only while the backfill runs gets no more notes.md written (F751)")
@MainActor
func backfillStopsWritingWhenTheLibraryDegradesMidPass() async throws {
    let (store, root, first, second) = try makeLibrary("degrade")
    defer { try? FileManager.default.removeItem(at: root) }
    let realPass = store.notesBackfillPass

    store.notesBackfillPass = { snapshot, libraryRoot in
        let firstOnly = snapshot.filter { $0.id == first.id }
        let rest = snapshot.filter { $0.id != first.id }
        let written = await realPass(firstOnly, libraryRoot)
        await MainActor.run {
            // Another copy empties the index over saved meetings (the 2026-08-14 shape); this
            // window's next save loses, re-reads, and the wipe check makes the library read-only.
            let rival = BackupJSONStore<[MeetingRecord]>(
                primaryURL: libraryRoot.appendingPathComponent("meetings.json"),
                backupURL: libraryRoot.appendingPathComponent("meetings.backup.json"),
                writer: "ffff9999",
                recordCount: { $0.count }
            )
            let seen = try? rival.load()
            _ = try? rival.save([], expecting: seen?.token)
            store.update(id: first.id) { $0.notes = "typed while the backfill ran" }
        }
        return written + (await realPass(rest, libraryRoot))
    }

    await store.backfillNotesSidecars()

    try #require(store.isDegraded, "precondition: the lost save made the library read-only, not \(store.health)")
    #expect(FileManager.default.fileExists(atPath: notesURL(first, root).path), "written before the state changed")
    #expect(!FileManager.default.fileExists(atPath: notesURL(second, root).path),
            "notes.md written into a read-only library")
}

@Test("A restore that begins while the backfill runs gets no notes.md written into its folders (F751)")
@MainActor
func backfillStopsWritingWhenARestoreBeginsMidPass() async throws {
    let (store, root, first, second) = try makeLibrary("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let realPass = store.notesBackfillPass

    store.notesBackfillPass = { snapshot, libraryRoot in
        let firstOnly = snapshot.filter { $0.id == first.id }
        let rest = snapshot.filter { $0.id != first.id }
        let written = await realPass(firstOnly, libraryRoot)
        await MainActor.run { store.beginLibraryRestore() }
        return written + (await realPass(rest, libraryRoot))
    }

    await store.backfillNotesSidecars()

    #expect(FileManager.default.fileExists(atPath: notesURL(first, root).path), "written before the state changed")
    #expect(!FileManager.default.fileExists(atPath: notesURL(second, root).path),
            "pre-restore notes.md written during a restore")

    // And the hold ending lets the next pass write again: the gate follows the state both ways.
    store.endLibraryRestore()
    store.notesBackfillPass = realPass
    await store.backfillNotesSidecars()
    #expect(FileManager.default.fileExists(atPath: notesURL(second, root).path))
}

@Test("Through the app, a restore cannot begin while startup recovery awaits the backfill (F751, F612)")
@MainActor
func restoreIsRefusedWhileStartupRecoveryAwaitsTheBackfill() async throws {
    // The ticket asked this to be confirmed by a test rather than by reading. Since F612 the restore
    // guard refuses while `performStartupRecovery` runs, and the backfill is awaited inside it, so the
    // app's own restore cannot reach case (2); the store-level gate above covers it regardless.
    let (store, root, _, _) = try makeLibrary("app")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        store: store,
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.runWhisperInstallRecovery = { _ in 0 }
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }
    let realPass = store.notesBackfillPass
    final class Seen: @unchecked Sendable { var refusal: String?; var offered = false; var ran = false }
    let seen = Seen()
    store.notesBackfillPass = { snapshot, libraryRoot in
        await MainActor.run { seen.ran = true }
        await model.requestLibraryRestore(from: libraryRoot.appendingPathComponent("no-such-backup"))
        await MainActor.run {
            seen.refusal = model.alertMessage
            seen.offered = model.pendingLibraryRestore != nil
        }
        return await realPass(snapshot, libraryRoot)
    }

    await model.performStartupRecovery()

    try #require(seen.ran, "precondition: startup recovery reached the backfill")
    #expect(seen.refusal == AppModel.startupRecoveryRestoreRefusal, "\(seen.refusal ?? "nil")")
    #expect(!seen.offered)
}
