import CryptoKit
import Foundation
import Testing
@testable import WhisperMeet

// F927 — F910's defect in a fourth place. `BackupCoordinator.hashAndCount` read each file 1 MiB at a
// time with `FileHandle.read(upToCount:)`, which returns each chunk in an autoreleased buffer, and no
// pool was drained inside the loop. Back Up Library runs the whole backup as one synchronous call
// inside `Task.detached` (`AppModel.backUpLibrary(to:)`): it hashes every library file up front, then
// hashes each copied file and its source again in `copyAndVerify`. So a backup held every byte it
// hashed until it returned. Measured before the fix: +66,388,016 bytes of footprint across one
// `hashAndCount` over a 64 MiB file.
//
// Measured with `heldMemory` (`HeldMemory.swift`): what ONE direct call left held, as the current
// footprint and as the bytes malloc has allocated, which an earlier test cannot mask.

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test("Hashing a file for a backup holds one chunk of it at a time, not all of it (F927)")
func backupHashHoldsOneChunkAtATime() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("F927-hash-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeDenseFile(at: url, mebibytes: 64, seed: 927)

    var measured: (sha256: String, byteCount: Int64)?
    let held = try heldMemory { measured = try BackupCoordinator.hashAndCount(of: url) }

    let result = try #require(measured)
    #expect(result.byteCount == Int64(64 << 20))
    #expect(result.sha256 == sha256Hex(try Data(contentsOf: url, options: .alwaysMapped)))
    // Every chunk kept is the whole 64 MiB; one chunk at a time is about 1 MiB.
    #expect(held.allocated < 16 << 20, "hashing a 64 MiB file left \(held) held")
    #expect(held.footprint < 16 << 20, "hashing a 64 MiB file left \(held) held")
}

@Test("A whole backup holds one chunk of what it hashes at a time, not every file it reads (F927)")
func backupHoldsOneChunkOfWhatItHashes() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("F927-backup-\(UUID().uuidString)")
    let source = tmp.appendingPathComponent("library")
    let destination = tmp.appendingPathComponent("backup")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let recording = source.appendingPathComponent("Recordings/A/meeting.wav")
    try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("meeting index".utf8).write(to: source.appendingPathComponent("meetings.json"))
    try writeDenseFile(at: recording, mebibytes: 32, seed: 928)

    var summary: BackupSummary?
    let held = try heldMemory {
        summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 1_000, retain: 2)
    }

    let backedUp = try #require(summary)
    #expect(backedUp.copied == 2)
    #expect(backedUp.verified)
    let copy = destination.appendingPathComponent("\(BackupCoordinator.managedSubfolder)/1000/Recordings/A/meeting.wav")
    #expect(try Data(contentsOf: copy, options: .alwaysMapped) == Data(contentsOf: recording, options: .alwaysMapped))
    // The 32 MiB recording is read three times: hashed up front, then the copy and the source are each
    // hashed again to verify it. Every chunk kept is about 96 MiB; one chunk at a time is about 1 MiB.
    #expect(held.allocated < 16 << 20, "backing up a 32 MiB recording left \(held) held")
    #expect(held.footprint < 16 << 20, "backing up a 32 MiB recording left \(held) held")
}
