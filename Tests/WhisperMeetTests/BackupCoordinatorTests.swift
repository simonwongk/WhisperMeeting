import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F90 — the BackupPlan/BackupRetention/BackupVerification core is wired into a BackupCoordinator that
// mirrors the library into timestamped generation snapshots on a chosen destination: unchanged files
// skip (hardlinked, not re-copied), changed/new files copy and verify, the source is never modified,
// and old generations prune under the retention policy.

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Test("BackupCoordinator snapshots changed files, verifies, never touches the source, and prunes (F90)")
func backupCoordinatorSnapshotsAndPrunes() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCoordinatorTests-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let dest = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("meeting index v1", to: source.appendingPathComponent("meetings.json"))
    try write("audio-A", to: source.appendingPathComponent("Recordings/A/meeting.wav"))

    // Generation 1: no prior snapshot → everything copies and verifies.
    let g1 = try BackupCoordinator.backUp(source: source, destination: dest, now: 1_000, retain: 2)
    #expect(g1.copied == 2)
    #expect(g1.skipped == 0)
    #expect(g1.verified)
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("1000/meetings.json").path))

    // Change one file, add another. Generation 2: unchanged file skips, changed + new copy.
    try write("meeting index v2", to: source.appendingPathComponent("meetings.json")) // changed
    try write("audio-B", to: source.appendingPathComponent("Recordings/B/meeting.wav")) // new
    let g2 = try BackupCoordinator.backUp(source: source, destination: dest, now: 2_000, retain: 2)
    #expect(g2.copied == 2)   // meetings.json (changed) + B (new)
    #expect(g2.skipped == 1)  // A/meeting.wav unchanged
    #expect(g2.verified)
    // The snapshot is complete regardless of skip/copy: the unchanged file is present too.
    let restoredA = try String(decoding: Data(contentsOf: dest.appendingPathComponent("2000/Recordings/A/meeting.wav")), as: UTF8.self)
    #expect(restoredA == "audio-A")
    let restoredIndex = try String(decoding: Data(contentsOf: dest.appendingPathComponent("2000/meetings.json")), as: UTF8.self)
    #expect(restoredIndex == "meeting index v2")

    // Generation 3 with retain: 2 → the oldest generation (1000) is pruned; 2000 and 3000 remain.
    let g3 = try BackupCoordinator.backUp(source: source, destination: dest, now: 3_000, retain: 2)
    #expect(g3.prunedGenerations.contains("1000"))
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("1000").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2000").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("3000").path))

    // The source library is byte-for-byte unchanged by any backup.
    #expect(try String(decoding: Data(contentsOf: source.appendingPathComponent("meetings.json")), as: UTF8.self) == "meeting index v2")
    #expect(try String(decoding: Data(contentsOf: source.appendingPathComponent("Recordings/A/meeting.wav")), as: UTF8.self) == "audio-A")
}

@MainActor
@Test("AppModel.backUpLibrary passes the store root + retention through to the coordinator seam (F90)")
func appModelBackUpLibraryReachesCoordinator() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupWiring-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F90.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.backupRetention = 3

    let box = Captured()
    model.runLibraryBackup = { source, destination, now, retain in
        box.source = source; box.destination = destination; box.retain = retain
        return BackupSummary(generation: String(now), copied: 4, skipped: 1, verified: true, prunedGenerations: [])
    }
    let dest = root.appendingPathComponent("dest")
    model.backUpLibrary(to: dest, now: 5_000)

    #expect(box.source?.standardizedFileURL == root.standardizedFileURL)   // the store's real root
    #expect(box.destination == dest)
    #expect(box.retain == 3)                                               // the Settings retention
    #expect(model.alertMessage?.contains("4 file(s) copied") == true)
}

private final class Captured: @unchecked Sendable {
    var source: URL?
    var destination: URL?
    var retain: Int?
}
