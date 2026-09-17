import CryptoKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice A + B — the snapshot did not contain what the UI promised, and taking it read whole
// files into memory.
//
// A. `backedUpEntries` was ["Recordings", "meetings.json", "vocabulary.json"]. Three defects, in
//    descending order of how visible they are to a user:
//    - `replacement-rules.json` was omitted entirely. The backup UI promises indexes and silently
//      dropped one of the three the app persists.
//    - Every `.backup.json` sibling was omitted, so a restored library has no redundancy behind a
//      single decode failure — the redundancy F190 exists to provide.
//    - Every `.ledger.json` was omitted. Checked: that does NOT make a restored library read as
//      divergent (`isDivergent` returns false without a ledger), so the cost is losing divergence
//      detection until the next save, not a quarantine.
//
// B. `sha256(of:)` was `SHA256.hash(data: try Data(contentsOf: url))`, so hashing a multi-GB
//    recording read all of it into memory at once.

@Test("The inventory names every index the app persists, with its backup and ledger")
func inventoryCoversEveryPersistedIndex() {
    let entries = Set(BackupCoordinator.backedUpEntries)
    // The three indexes the app actually writes, each with the two siblings F190 gives it.
    for stem in ["meetings", "vocabulary", "replacement-rules"] {
        #expect(entries.contains("\(stem).json"), "\(stem).json is not backed up")
        #expect(entries.contains("\(stem).backup.json"), "\(stem).backup.json is not backed up")
        #expect(entries.contains("\(stem).ledger.json"), "\(stem).ledger.json is not backed up")
    }
    #expect(entries.contains("Recordings"))
}

@Test("The exclusions are deliberate and named, not omissions")
func exclusionsAreDeliberate() {
    let entries = Set(BackupCoordinator.backedUpEntries)
    // `meetings.history/` is a short undo window, not an archive — the ticket says so explicitly,
    // and copying it into every generation would multiply a rolling buffer by the retain count.
    #expect(!entries.contains("meetings.history"))
    // Install logs and downloaded runtimes are not user data and are re-creatable.
    #expect(!entries.contains("qwen-install.log"))
    #expect(!entries.contains("Qwen"))
}

@Test("A backup copies all three indexes and their siblings, not just two files")
func backupCopiesTheWholeInventory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupInv-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A library with all three indexes, each with a backup and a ledger, plus one recording.
    for stem in ["meetings", "vocabulary", "replacement-rules"] {
        for suffix in ["json", "backup.json", "ledger.json"] {
            try Data("\(stem)-\(suffix)".utf8)
                .write(to: source.appendingPathComponent("\(stem).\(suffix)"))
        }
    }
    let folder = source.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    // Deliberately excluded: present in the source, must not appear in the generation.
    let history = source.appendingPathComponent("meetings.history", isDirectory: true)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    try Data("undo".utf8).write(to: history.appendingPathComponent("0001.json"))

    let summary = try BackupCoordinator.backUp(
        source: source, destination: destination, now: 1, retain: 3
    )
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent("1", isDirectory: true)

    for stem in ["meetings", "vocabulary", "replacement-rules"] {
        for suffix in ["json", "backup.json", "ledger.json"] {
            let copied = generation.appendingPathComponent("\(stem).\(suffix)")
            #expect(
                FileManager.default.fileExists(atPath: copied.path),
                "\(stem).\(suffix) missing from the generation"
            )
        }
    }
    #expect(FileManager.default.fileExists(
        atPath: generation.appendingPathComponent("Recordings/\(folder.lastPathComponent)/meeting.wav").path
    ))
    // The undo window stayed out.
    #expect(!FileManager.default.fileExists(
        atPath: generation.appendingPathComponent("meetings.history").path
    ))
    #expect(summary.copied == 10)   // 9 index files + 1 recording
}

@Test("A library missing some indexes backs up the ones it has, without failing")
func partialLibraryBacksUpWhatExists() throws {
    // A fresh install has no `replacement-rules.json` and no ledgers until the first save. The
    // inventory is a list of candidates, not a set of requirements — demanding all of them would
    // make the backup feature fail on a new library, which is the shape of bug that turns a safety
    // feature into an obstacle.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupPartial-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("only-this".utf8).write(to: source.appendingPathComponent("meetings.json"))

    let summary = try BackupCoordinator.backUp(
        source: source, destination: destination, now: 7, retain: 2
    )
    #expect(summary.copied == 1)
}

// MARK: - B: streaming the hash

@Test("The streamed hash matches the whole-file hash, across chunk boundaries")
func streamedHashMatchesWholeFile() throws {
    // Sizes chosen around the chunk boundary: a hash that is right for a small file and wrong at
    // the seam is the defect a single-size test misses.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HashChunks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let chunk = BackupCoordinator.hashChunkByteCount
    for size in [0, 1, chunk - 1, chunk, chunk + 1, chunk * 2, chunk * 2 + 17] {
        let url = directory.appendingPathComponent("size-\(size).bin")
        var bytes = Data(count: size)
        for index in 0..<size { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: url)

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try BackupCoordinator.sha256(of: url) == expected, "mismatch at \(size) bytes")
    }
}

@Test("Hashing a large file does not read it all into memory")
func largeFileIsHashedInChunks() throws {
    // The property, made observable: count how many times the reader is asked for data. A
    // whole-file read asks once for everything; a streamed one asks repeatedly for a bounded
    // amount. Asserting "memory did not grow" is not something a test can do honestly, so this
    // asserts the mechanism that makes it true.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HashLarge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("large.bin")
    let size = BackupCoordinator.hashChunkByteCount * 5 + 3
    try Data(repeating: 0xAB, count: size).write(to: url)

    var readSizes: [Int] = []
    let digest = try BackupCoordinator.sha256(of: url) { handle, count in
        let data = try handle.read(upToCount: count)
        readSizes.append(data?.count ?? 0)
        return data
    }
    #expect(digest == SHA256.hash(data: Data(repeating: 0xAB, count: size))
        .map { String(format: "%02x", $0) }.joined())
    // Six reads of bounded size plus the terminating empty one, never one read of everything.
    #expect(readSizes.count >= 6)
    #expect(readSizes.allSatisfy { $0 <= BackupCoordinator.hashChunkByteCount })
}
