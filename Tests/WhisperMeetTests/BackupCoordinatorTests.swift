import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F90 + F137 — BackupCoordinator mirrors the meeting library into timestamped generation snapshots under
// a dedicated managed subfolder: changed/new files copy and verify, unchanged files hardlink, the source
// is never modified, and only OUR complete generations are pruned — never unrelated user folders.

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// The managed subfolder a backup writes its generations into, inside the chosen destination.
private func backupRoot(_ chosen: URL) -> URL {
    chosen.appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
}

// F90 (audit fix) — the free-space check must only reject on a CREDIBLE positive reading below the need.
@Test("Backup free-space check treats 0/unknown capacity as 'do not block' (F90 audit)")
func backupFreeSpaceCheckTreatsUnknownAsAvailable() {
    #expect(BackupCoordinator.shouldRejectForSpace(available: nil, needed: 100) == false)
    #expect(BackupCoordinator.shouldRejectForSpace(available: 0, needed: 100) == false)
    #expect(BackupCoordinator.shouldRejectForSpace(available: 50, needed: 100) == true)
    #expect(BackupCoordinator.shouldRejectForSpace(available: 200, needed: 100) == false)
    #expect(BackupCoordinator.shouldRejectForSpace(available: 100, needed: 0) == false)
}

@Test("BackupCoordinator snapshots changed files under the managed subfolder, verifies, and prunes (F90)")
func backupCoordinatorSnapshotsAndPrunes() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCoordinatorTests-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let dest = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("meeting index v1", to: source.appendingPathComponent("meetings.json"))
    try write("audio-A", to: source.appendingPathComponent("Recordings/A/meeting.wav"))
    let root = backupRoot(dest)

    let g1 = try BackupCoordinator.backUp(source: source, destination: dest, now: 1_000, retain: 2)
    #expect(g1.copied == 2)
    #expect(g1.skipped == 0)
    #expect(g1.verified)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("1000/meetings.json").path))

    try write("meeting index v2", to: source.appendingPathComponent("meetings.json")) // changed
    try write("audio-B", to: source.appendingPathComponent("Recordings/B/meeting.wav")) // new
    let g2 = try BackupCoordinator.backUp(source: source, destination: dest, now: 2_000, retain: 2)
    #expect(g2.copied == 2)
    #expect(g2.skipped == 1)
    #expect(g2.verified)
    let restoredA = try String(decoding: Data(contentsOf: root.appendingPathComponent("2000/Recordings/A/meeting.wav")), as: UTF8.self)
    #expect(restoredA == "audio-A")
    let restoredIndex = try String(decoding: Data(contentsOf: root.appendingPathComponent("2000/meetings.json")), as: UTF8.self)
    #expect(restoredIndex == "meeting index v2")

    let g3 = try BackupCoordinator.backUp(source: source, destination: dest, now: 3_000, retain: 2)
    #expect(g3.prunedGenerations.contains("1000"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1000").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2000").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("3000").path))

    #expect(try String(decoding: Data(contentsOf: source.appendingPathComponent("meetings.json")), as: UTF8.self) == "meeting index v2")
}

// F137 — pruning must NEVER touch a user folder that merely has a numeric name; generations live only in
// the managed subfolder, and only OUR complete generations are prunable.
@Test("Backup never prunes unrelated numeric-named folders in the chosen destination (F137)")
func backupNeverPrunesUnrelatedNumericFolders() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupSafety-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let dest = tmp.appendingPathComponent("MyDocuments")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("v1", to: source.appendingPathComponent("meetings.json"))
    // A pre-existing user folder that happens to be named with a year.
    try write("precious", to: dest.appendingPathComponent("2024/receipts.txt"))

    for now in [1_000, 2_000, 3_000] {
        _ = try BackupCoordinator.backUp(source: source, destination: dest, now: now, retain: 1)
    }

    // The user's 2024 folder is untouched, even though retain:1 pruned older generations.
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2024/receipts.txt").path))
    #expect(try String(decoding: Data(contentsOf: dest.appendingPathComponent("2024/receipts.txt")), as: UTF8.self) == "precious")
    // Generations live under the managed subfolder, and retain:1 kept only the newest.
    #expect(FileManager.default.fileExists(atPath: backupRoot(dest).appendingPathComponent("3000").path))
    #expect(!FileManager.default.fileExists(atPath: backupRoot(dest).appendingPathComponent("1000").path))
}

// F137 — refuse to back up into the library itself or a child/parent of it (would grow recursively).
@Test("Backup refuses when source and destination overlap (F137)")
func backupRefusesOverlappingSourceAndDestination() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupOverlap-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("v1", to: source.appendingPathComponent("meetings.json"))

    // Destination inside source.
    #expect(throws: (any Error).self) {
        _ = try BackupCoordinator.backUp(source: source, destination: source.appendingPathComponent("backups"), now: 1_000, retain: 2)
    }
    // Destination == source.
    #expect(throws: (any Error).self) {
        _ = try BackupCoordinator.backUp(source: source, destination: source, now: 1_000, retain: 2)
    }
    // Source inside destination.
    #expect(throws: (any Error).self) {
        _ = try BackupCoordinator.backUp(source: source, destination: tmp, now: 1_000, retain: 2)
    }
}

// F137 — an interrupted generation (no completion marker) is never counted or pruned as a real backup,
// and successful generations are marked complete.
@Test("Backup marks generations complete and ignores partial (unmarked) ones (F137)")
func backupMarksCompleteAndIgnoresPartials() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupMarker-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let dest = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("v1", to: source.appendingPathComponent("meetings.json"))
    // A leftover partial generation from an interrupted run: a numeric dir with no completion marker.
    try write("half", to: backupRoot(dest).appendingPathComponent("500/meetings.json"))

    let g1 = try BackupCoordinator.backUp(source: source, destination: dest, now: 1_000, retain: 5)
    // The new generation is marked complete.
    #expect(FileManager.default.fileExists(atPath: backupRoot(dest).appendingPathComponent("1000/\(BackupCoordinator.completionMarker)").path))
    // The partial 500 was not treated as a prior generation to hardlink-from, and is cleaned up.
    #expect(!FileManager.default.fileExists(atPath: backupRoot(dest).appendingPathComponent("500").path))
    #expect(g1.copied == 1) // meetings.json copied fresh (no valid previous generation)
}

// F137 — only the meeting library is backed up, not the whole Application Support dir (models/runtimes).
@Test("Backup includes only the library entries, not installed runtimes/models (F137)")
func backupScopesToLibraryEntries() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupScope-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("WhisperMeet")
    let dest = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("index", to: source.appendingPathComponent("meetings.json"))
    try write("vocab", to: source.appendingPathComponent("vocabulary.json"))
    try write("audio", to: source.appendingPathComponent("Recordings/A/meeting.wav"))
    try write("HUGE MODEL WEIGHTS", to: source.appendingPathComponent("Runtime/Qwen3ASR/model/model.safetensors"))

    _ = try BackupCoordinator.backUp(source: source, destination: dest, now: 1_000, retain: 2)
    let gen = backupRoot(dest).appendingPathComponent("1000")
    #expect(FileManager.default.fileExists(atPath: gen.appendingPathComponent("meetings.json").path))
    #expect(FileManager.default.fileExists(atPath: gen.appendingPathComponent("vocabulary.json").path))
    #expect(FileManager.default.fileExists(atPath: gen.appendingPathComponent("Recordings/A/meeting.wav").path))
    #expect(!FileManager.default.fileExists(atPath: gen.appendingPathComponent("Runtime").path)) // models excluded
}

@MainActor
@Test("AppModel.backUpLibrary passes the store root + retention through to the coordinator seam (F90)")
func appModelBackUpLibraryReachesCoordinator() async throws {
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
    await model.backUpLibrary(to: dest, now: 5_000)

    #expect(box.source?.standardizedFileURL == root.standardizedFileURL)
    #expect(box.destination == dest)
    #expect(box.retain == 3)
    #expect(model.alertMessage?.contains("4 file(s) copied") == true)
}

// F504 — a backup used to hash every source file up front, then verify each COPY against that
// stale hash. `meetings.json` changing anywhere in the run — a debounced save, a batch
// transcription finishing — made the copy of its own current bytes fail verification against the
// hash of what it used to contain, and the whole backup was refused for a copy that was in fact
// faithful. `beforeProcessingForTesting` fires once per plan item, right before it is copied —
// exactly the moment `descriptors(of:)`'s up-front hash is already stale but the copy has not
// happened yet — so mutating `meetings.json` from it reproduces the report with no clock and no
// real concurrent writer.

@Test("A source file that changes after being hashed but before being copied no longer fails the backup (F504)")
func sourceChangedMidRunNoLongerFailsVerification() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("F504-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let dest = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("meetings v1", to: source.appendingPathComponent("meetings.json"))
    try write("audio-A", to: source.appendingPathComponent("Recordings/A/meeting.wav"))

    let summary = try BackupCoordinator.backUp(
        source: source, destination: dest, now: 1_000, retain: 2,
        beforeProcessingForTesting: { relativePath in
            // Simulates a debounced index save landing after the up-front scan hashed the OLD
            // content but before this file's own copy step runs.
            if relativePath == "meetings.json" {
                try? Data("meetings v2 (saved mid-backup)".utf8).write(to: source.appendingPathComponent("meetings.json"))
            }
        }
    )

    #expect(summary.verified)
    #expect(summary.copied == 2)
    let backedUpIndex = try String(
        decoding: Data(contentsOf: backupRoot(dest).appendingPathComponent("1000/meetings.json")), as: UTF8.self
    )
    // The backup holds the NEW bytes — what was actually on disk when it was copied — not the
    // stale up-front snapshot and not a refusal.
    #expect(backedUpIndex == "meetings v2 (saved mid-backup)")
}

@Test("copyAndVerify retries once against a changed source, bounded rather than looping forever (F504)")
func copyAndVerifyRetriesOnceThenGivesUp() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("F504-unit-\(UUID().uuidString)")
    let sourceURL = tmp.appendingPathComponent("meetings.json")
    let destURL = tmp.appendingPathComponent("copy/meetings.json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("v1", to: sourceURL)
    // `copyItem` needs its destination's parent directory to already exist — `backUp`'s own loop
    // creates it before calling `copyAndVerify`; these standalone unit tests must do the same.
    try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Mutates the source on every attempt — a pathological case (a continuously rewritten file),
    // never one debounced save settling. The retry must still be bounded: this must throw rather
    // than retry indefinitely.
    var sleeps = 0
    var attempts = 0
    #expect(throws: BackupCoordinatorError.self) {
        _ = try BackupCoordinator.copyAndVerify(
            from: sourceURL, to: destURL, relativePath: "meetings.json",
            retryDelay: 0,
            sleep: { _ in sleeps += 1 },
            afterCopyForTesting: { attempt in
                attempts += 1
                try? Data("v\(attempt + 1)".utf8).write(to: sourceURL)
            }
        )
    }
    #expect(attempts == 2, "exactly two attempts — the bound, not unbounded retrying")
    #expect(sleeps == 1, "exactly one wait, between the two attempts")
}

@Test("copyAndVerify succeeds once the source stabilises within its one retry (F504)")
func copyAndVerifySucceedsAfterOneRetry() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("F504-unit-\(UUID().uuidString)")
    let sourceURL = tmp.appendingPathComponent("meetings.json")
    let destURL = tmp.appendingPathComponent("copy/meetings.json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write("v1", to: sourceURL)
    // `copyItem` needs its destination's parent directory to already exist — `backUp`'s own loop
    // creates it before calling `copyAndVerify`; these standalone unit tests must do the same.
    try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    var sleepCalls = 0
    let hash = try BackupCoordinator.copyAndVerify(
        from: sourceURL, to: destURL, relativePath: "meetings.json",
        retryDelay: 0,
        sleep: { _ in sleepCalls += 1 },
        afterCopyForTesting: { attempt in
            // Only the FIRST attempt's copy is immediately invalidated by a source write — exactly
            // a debounced save landing right after that copy. By the retry (attempt 2), the source
            // is stable again, the way a real save would be well within the debounce window.
            if attempt == 1 {
                try? Data("v2 (saved mid-copy)".utf8).write(to: sourceURL)
            }
        }
    )
    #expect(sleepCalls == 1, "exactly one retry was needed")
    #expect(hash == (try BackupCoordinator.sha256(of: destURL)))
    #expect(try String(decoding: Data(contentsOf: destURL), as: UTF8.self) == "v2 (saved mid-copy)")
}

private final class Captured: @unchecked Sendable {
    var source: URL?
    var destination: URL?
    var retain: Int?
}
