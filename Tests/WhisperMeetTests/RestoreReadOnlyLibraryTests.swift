import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F466 — restoring a backup is allowed while the library is read-only, the one state it exists
// to repair.
//
// A read-only library refuses every change, and the restore was refused with it: "Restoring the
// library cannot start because … resolve recovery first". But when the index and its backup copy
// are unreadable and no earlier generation was kept, Recover Library has nothing to offer, and a
// full backup made with "Back up library…" is the user's way out. `MeetingStore` states the rule
// for its own index restores: a recovery action refused for being read-only leaves exactly the dead
// end F193 was filed for.
//
// A restore does not go through the store's write path at all — it copies files, keeps the
// library's previous state aside first, and reloads — so nothing the read-only guard protects is
// put at risk by letting it run.

/// A library backed up while healthy, then damaged past what the store can read.
@MainActor
private func makeDamagedLibrary(_ label: String) throws -> (root: URL, model: AppModel, generation: URL, id: UUID) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreReadOnly-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let id = UUID()
    let folder = library.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    do {
        // A long debounce, so this store never writes the notes sidecar the re-run is tested by.
        let writer = MeetingStore(rootDirectory: library, transcriptWriteDebounce: 3_600)
        writer.upsert(MeetingRecord(
            id: id, title: "At the backup", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: "What was said.", languageCode: "en"
        ))
    }
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)

    // Both copies of the index gone bad, as in the ticket.
    try Data("not an index".utf8).write(to: library.appendingPathComponent("meetings.json"))
    try? FileManager.default.removeItem(at: library.appendingPathComponent("meetings.backup.json"))

    let model = AppModel(
        store: MeetingStore(rootDirectory: library),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "WhisperMeet.RestoreReadOnly.\(UUID().uuidString)")!
    )
    // Startup recovery runs below; nothing in it may spawn an installer from a test.
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }
    return (root, model, generation, id)
}

@Test("A read-only library can be restored from a backup (F466)")
@MainActor
func readOnlyLibraryCanBeRestored() async throws {
    let (root, model, generation, id) = try makeDamagedLibrary("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.isDegraded, "precondition: the damaged library opens read-only")

    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore != nil, "refused: \(model.alertMessage ?? "no message")")
    await model.performLibraryRestore(confirmed: true)?.value

    #expect(!model.store.isDegraded, "still read-only after the restore: \(model.store.health)")
    #expect(model.store.meetings.map(\.id) == [id])
    #expect(model.alertMessage?.contains("was restored from the backup") == true, "\(model.alertMessage ?? "")")
}

@Test("Restoring a read-only library resumes the startup work it skipped (F466)")
@MainActor
func restoreResumesSkippedStartupWork() async throws {
    // The launch stops early on a read-only library — no notes backfill, no interrupted-recording
    // rebuild — and marks itself done. Recover Library resets and re-runs it (F193); a restore that
    // makes the library writable has to do the same, or that work waits for a relaunch nobody is
    // told to do. The notes sidecar is the observable part of it here.
    let (root, model, generation, id) = try makeDamagedLibrary("resume")
    defer { try? FileManager.default.removeItem(at: root) }
    await model.performStartupRecovery()
    let notes = model.store.rootDirectory.appendingPathComponent("Recordings/\(id.uuidString)/notes.md")
    try #require(!FileManager.default.fileExists(atPath: notes.path), "precondition: the read-only launch wrote nothing")

    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore != nil, "refused: \(model.alertMessage ?? "no message")")
    await model.performLibraryRestore(confirmed: true)?.value

    // The re-run is started, not awaited, by the restore — so waiting for its product is this
    // assertion's own subject rather than a precondition for a different claim.
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: notes.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: notes.path), "startup recovery did not run again")
}
