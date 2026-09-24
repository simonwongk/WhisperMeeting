import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F463 — an index's files describe one lineage, so a restore replaces them as a set.
//
// Each index is kept in three files: `meetings.json`, the previous generation in
// `meetings.backup.json`, and `meetings.ledger.json` recording which generation is current. A
// backup made before F191 slice A holds only `meetings.json`, and every such backup is still offered
// through Restore Anyway. Restoring one replaced the index and left the live ledger and backup copy
// beside it — a ledger describing a generation that was no longer there, with the live history
// holding it. On reload that reads as two writers on divergent branches, so the library opened
// read-only, while the app announced the restore had worked.

private let legacyIndex = #"[{"id":"4B0C2F10-0000-4000-8000-000000000463","title":"From the old backup","createdAt":"2026-01-05T10:00:00Z","duration":60,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]"#

/// A live library written through the real store, several times, so it has everything a library
/// in use has: a ledger, a backup copy, and a history holding the current generation.
@MainActor
private func makeLiveLibrary(_ label: String) throws -> (root: URL, library: URL, model: AppModel) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreLineage-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: library),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "WhisperMeet.RestoreLineage.\(UUID().uuidString)")!
    )
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Live, first", status: .recorded))
    model.store.update(id: id) { $0.title = "Live, second" }
    model.store.update(id: id) { $0.title = "Live, third" }
    return (root, library, model)
}

/// A generation as a pre-F191 backup wrote it: an index and the completion marker, nothing else.
private func makeLegacyGeneration(in root: URL, index: String) throws -> URL {
    let generation = root
        .appendingPathComponent("Dest/\(BackupCoordinator.managedSubfolder)/1700000000", isDirectory: true)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try Data(index.utf8).write(to: generation.appendingPathComponent("meetings.json"))
    try Data().write(to: generation.appendingPathComponent(BackupCoordinator.completionMarker))
    return generation
}

private func snapshot(in library: URL) throws -> URL {
    let name = try #require(
        try FileManager.default.contentsOfDirectory(atPath: library.path)
            .first { $0.hasPrefix(".pre-restore-") }
    )
    return library.appendingPathComponent(name, isDirectory: true)
}

@Test("Restoring a backup with no ledger leaves a library that opens writable (F463)")
@MainActor
func legacyRestoreLeavesAWritableLibrary() async throws {
    let (root, library, model) = try makeLiveLibrary("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    // The precondition that makes this case: the live library really has a lineage to leave behind.
    try #require(FileManager.default.fileExists(atPath: library.appendingPathComponent("meetings.ledger.json").path))
    try #require(FileManager.default.fileExists(atPath: library.appendingPathComponent("meetings.backup.json").path))
    let generation = try makeLegacyGeneration(in: root, index: legacyIndex)

    await model.requestLibraryRestore(from: generation)
    let pending = try #require(model.pendingLibraryRestore)
    try #require(pending.plan.requiresExplicitOverride)
    // The live lineage files are not "files recorded since that backup, left on disk": the
    // confirmation must not count them as such.
    #expect(!pending.plan.notInBackup.contains("meetings.ledger.json"), "\(pending.plan.notInBackup)")
    #expect(!pending.plan.notInBackup.contains("meetings.backup.json"), "\(pending.plan.notInBackup)")

    await model.performLibraryRestore(confirmed: true, acceptingUnverifiedBackup: true)?.value

    #expect(!model.store.isDegraded, "the restored library opened as \(model.store.health)")
    #expect(model.store.meetings.map(\.title) == ["From the old backup"])
    // A later launch reads the same files and must agree.
    #expect(!MeetingStore(rootDirectory: library).isDegraded, "the next launch would open it read-only")
    // The live lineage went into the kept copy, where undoing the restore needs it — not the bin.
    let kept = try snapshot(in: library)
    #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("meetings.ledger.json").path))
    #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("meetings.backup.json").path))
}

@Test("Only the lineage of an index the backup replaces is set aside (F463)")
@MainActor
func onlyTheReplacedIndexLosesItsLineage() throws {
    // The legacy generation has `meetings.json` and nothing for vocabulary, so the live vocabulary
    // stays — and so must its ledger, which still describes it correctly.
    let (root, library, model) = try makeLiveLibrary("scope")
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.addVocabulary(["Kubernetes"])
    try #require(FileManager.default.fileExists(atPath: library.appendingPathComponent("vocabulary.ledger.json").path))
    let generation = try makeLegacyGeneration(in: root, index: legacyIndex)

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)

    #expect(plan.wouldSetAside == ["meetings.backup.json", "meetings.ledger.json"])
}

@Test("A restore that fails puts the set-aside lineage back (F463)")
@MainActor
func failedRestorePutsTheLineageBack() throws {
    // Removing live files is new for a restore, so the rollback is shown to undo it by making the
    // copy fail, as `failedRestoreRollsBack` does for the files it overwrites.
    let (root, library, _) = try makeLiveLibrary("rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = library.appendingPathComponent("meetings.ledger.json")
    let ledgerBefore = try Data(contentsOf: ledger)
    let generation = try makeLegacyGeneration(in: root, index: legacyIndex)
    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    try #require(plan.wouldSetAside.contains("meetings.ledger.json"))

    struct CopyFailed: Error {}
    #expect(throws: CopyFailed.self) {
        try BackupRestore.apply(plan, from: generation, into: library, acceptingUnverifiedBackup: true) { _, _ in
            throw CopyFailed()
        }
    }
    #expect((try? Data(contentsOf: ledger)) == ledgerBefore, "the live ledger was not put back")
    #expect(!MeetingStore(rootDirectory: library).isDegraded)
}

@Test("A restore that leaves the library unreadable says so instead of announcing success (F463)")
@MainActor
func unreadableRestoreIsNotAnnouncedAsSuccess() async throws {
    let (root, _, model) = try makeLiveLibrary("unreadable")
    defer { try? FileManager.default.removeItem(at: root) }
    // A legacy backup carries no checksums, so an index damaged inside it is only discovered when
    // the restored library is read.
    let generation = try makeLegacyGeneration(in: root, index: "not an index")

    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore?.plan.requiresExplicitOverride == true)
    await model.performLibraryRestore(confirmed: true, acceptingUnverifiedBackup: true)?.value

    try #require(model.store.isDegraded, "precondition: the restored index does not decode")
    let message = model.alertMessage ?? ""
    #expect(!message.contains("was restored from the backup"), "\(message)")
    #expect(message.contains("read-only"), "\(message)")
    // The way back is still named.
    #expect(message.contains(".pre-restore-"), "\(message)")
}
