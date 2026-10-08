import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F604 — after a backup restore, the restore's own saves are the newest generations.
//
// F463 made a restore set the live ledger aside when the backup has none, and left
// `meetings.history/` where it was. With no ledger the next save was numbered 1, below the
// pre-restore generations already in the history, so those kept retention's "newest three" slots,
// the restore's own saves were the ones pruned, and the recovery list offered the pre-restore
// copies first — inviting the user to undo their restore by accident.

private let legacyIndex = #"[{"id":"4B0C2F10-0000-4000-8000-000000000604","title":"From the old backup","createdAt":"2026-01-05T10:00:00Z","duration":60,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]"#

@Test("After restoring a ledger-less backup, the next three saves are retained and listed first (F604)")
@MainActor
func postRestoreSavesAreNumberedAboveTheLiveHistory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreSequence-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: MeetingStore(rootDirectory: library), recorder: AudioCaptureEngine(), defaults: defaults)

    // The ticket's shape: a library in use whose history has reached generation 57.
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Live 1", status: .recorded))
    for index in 2...57 {
        model.store.update(id: id) { $0.title = "Live \(index)" }
    }
    let liveNewest = try #require(try model.store.indexGenerations().first)
    try #require(liveNewest.sequence == 57, "precondition: the live history reached 57, not \(liveNewest.sequence)")

    // A backup made before F191 slice A: an index and its completion marker, no ledger.
    let generation = root
        .appendingPathComponent("Dest/\(BackupCoordinator.managedSubfolder)/1700000000", isDirectory: true)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try Data(legacyIndex.utf8).write(to: generation.appendingPathComponent("meetings.json"))
    try Data().write(to: generation.appendingPathComponent(BackupCoordinator.completionMarker))
    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore?.plan.wouldSetAside.contains("meetings.ledger.json") == true)
    await model.performLibraryRestore(confirmed: true, acceptingUnverifiedBackup: true)?.value
    try #require(!model.store.isDegraded, "precondition: the restored library opened as \(model.store.health)")
    let restoredID = try #require(model.store.meetings.first?.id)

    // Three ordinary saves after the restore, each one's bytes fingerprinted as it lands.
    var postRestore: [String] = []
    for index in 1...3 {
        model.store.update(id: restoredID) { $0.title = "After restore \(index)" }
        let bytes = try Data(contentsOf: library.appendingPathComponent("meetings.json"))
        postRestore.append(StoreFingerprint.of(bytes))
    }

    let listed = try model.store.indexGenerations()
    let expected: [String] = postRestore.reversed()
    #expect(
        Array(listed.prefix(3).map(\.fingerprint)) == expected,
        "listed first: \(listed.prefix(5).map { "\($0.sequence)" })"
    )
    for fingerprint in postRestore {
        #expect(listed.contains { $0.fingerprint == fingerprint }, "a post-restore save was pruned")
    }
    #expect((listed.first?.sequence ?? 0) > 57, "numbered below the history already on disk")
    // The last pre-restore state is still in the kept copy the restore made (F463), so the user
    // can undo the restore whatever retention does to the older generations from here on.
    let snapshot = try #require(
        try FileManager.default.contentsOfDirectory(atPath: library.path).first { $0.hasPrefix(".pre-restore-") }
    )
    let keptPrimary = try Data(contentsOf: library.appendingPathComponent("\(snapshot)/meetings.json"))
    #expect(StoreFingerprint.of(keptPrimary) == liveNewest.fingerprint)
}
