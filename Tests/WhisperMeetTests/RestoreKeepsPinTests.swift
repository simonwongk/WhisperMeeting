import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F677, through the app — the path the ticket names. A backup restore whose backup carries no
// ledger sets the live one aside (F463) and leaves `meetings.history/` where it is. The high-water
// pin reads counts only from the ledger, so every pre-restore generation lost its count with it, and
// the largest library on disk — the one a restore that shrank the library would most need — was
// pruned by the ordinary rules within three saves.

private let legacyIndex = #"[{"id":"4B0C2F10-0000-4000-8000-000000000677","title":"From the old backup","createdAt":"2026-01-05T10:00:00Z","duration":60,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]"#

@Test("After restoring a ledger-less backup, the largest pre-restore library is still kept (F677)")
@MainActor
func aRestoreDoesNotCostThePin() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreKeepsPin-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: MeetingStore(rootDirectory: library), recorder: AudioCaptureEngine(), defaults: defaults)

    // A library of five meetings: its last save is the high-water generation the pin keeps.
    for index in 1...5 {
        model.store.upsert(MeetingRecord(id: UUID(), title: "Live \(index)", status: .recorded))
    }
    try #require(try model.store.indexGenerations().contains { $0.recordCount == 5 })

    // A backup made before F191 slice A: one meeting, no ledger.
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

    // Saves written seconds apart, so no age anchor can hold the five: only the pin can.
    for index in 1...4 {
        model.store.update(id: restoredID) { $0.title = "After restore \(index)" }
    }

    let listed = try model.store.indexGenerations()
    let described = listed.map { "\($0.sequence)=\($0.recordCount.map(String.init) ?? "nil")" }
    let five = try #require(listed.first { $0.recordCount == 5 }, "the five-meeting library was pruned: \(described)")
    // Counted from its bytes, not merely labelled: it really is the five meetings.
    let bytes = try Data(contentsOf: library.appendingPathComponent("meetings.history/\(five.name)"))
    let elements = try JSONSerialization.jsonObject(with: bytes) as? [Any]
    #expect(elements?.count == 5)
}
