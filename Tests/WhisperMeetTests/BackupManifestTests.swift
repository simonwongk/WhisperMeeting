import CryptoKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice D — a generation could say "complete" and be damaged.
//
// Completeness rested entirely on the presence of an EMPTY marker file. That is a true statement
// about the run that wrote it and says nothing about the bytes: after publication a generation can
// be truncated by a failing disk, a sync client, a partial copy to another volume, or a user moving
// files. The marker still says complete.
//
// That matters most for slice E. A restore writes a generation over the user's live library, so it
// has to be able to tell whether what it is about to copy is intact — and an empty file cannot
// answer that.
//
// **The ticket calls this "authenticated" and it is not; it is INTEGRITY.** Authentication needs a
// secret, and there is nowhere to keep one that an attacker who can rewrite the manifest could not
// also read — the key would sit in the same folder. What this honestly detects is accidental
// corruption and truncation, not a deliberate forger. Claiming otherwise would be the kind of
// promise this codebase keeps catching itself making.

private func makeLibrary(_ label: String) throws -> (root: URL, source: URL, destination: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupMan-\(label)-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("meetings-index".utf8).write(to: source.appendingPathComponent("meetings.json"))
    let folder = source.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("some-audio-bytes".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    return (root, source, destination)
}

private func generationURL(_ destination: URL, _ id: String) -> URL {
    destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
}

@Test("A published generation carries a manifest of every file it holds")
func generationCarriesAManifest() throws {
    let (root, source, destination) = try makeLibrary("written")
    defer { try? FileManager.default.removeItem(at: root) }

    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 1, retain: 3)
    let generation = generationURL(destination, summary.generation)
    let manifest = try #require(BackupManifest.read(in: generation))

    #expect(manifest.generation == "1")
    #expect(manifest.files.count == 2)
    #expect(manifest.files.contains { $0.relativePath == "meetings.json" })
    #expect(manifest.files.contains { $0.relativePath.hasSuffix("meeting.wav") })
    // The manifest describes itself too, so a truncated one is detectable without the files.
    #expect(!manifest.digest.isEmpty)
}

@Test("An intact generation verifies")
func intactGenerationVerifies() throws {
    let (root, source, destination) = try makeLibrary("intact")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 2, retain: 3)

    let result = try BackupManifest.verify(in: generationURL(destination, summary.generation), deep: false)
    #expect(result.isIntact)
    #expect(result.problems.isEmpty)
    // And the deep check agrees, at the cost of hashing everything.
    #expect(try BackupManifest.verify(
        in: generationURL(destination, summary.generation), deep: true
    ).isIntact)
}

@Test("A missing file is caught by the cheap check")
func missingFileIsCaught() throws {
    let (root, source, destination) = try makeLibrary("missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 3, retain: 3)
    let generation = generationURL(destination, summary.generation)
    try FileManager.default.removeItem(at: generation.appendingPathComponent("meetings.json"))

    let result = try BackupManifest.verify(in: generation, deep: false)
    #expect(!result.isIntact)
    #expect(result.problems.contains { $0.contains("meetings.json") })
}

@Test("A truncated file is caught by the cheap check, because size is in the manifest")
func truncatedFileIsCaught() throws {
    // Truncation is the common corruption — an interrupted copy to another volume, a sync client
    // that wrote half — and it is catchable without hashing anything, which is what makes the
    // cheap check worth having rather than only the deep one.
    let (root, source, destination) = try makeLibrary("truncated")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 4, retain: 3)
    let generation = generationURL(destination, summary.generation)
    try Data("short".utf8).write(to: generation.appendingPathComponent("meetings.json"))

    let result = try BackupManifest.verify(in: generation, deep: false)
    #expect(!result.isIntact)
}

@Test("Silent corruption at the same size needs the deep check, and the cheap one says so")
func sameSizeCorruptionNeedsTheDeepCheck() throws {
    // The honest limit of the cheap check, asserted rather than left for someone to discover: a
    // file rewritten to the same length passes it. This is why `deep` exists and why a restore
    // must not treat the cheap result as proof of content.
    let (root, source, destination) = try makeLibrary("silent")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 5, retain: 3)
    let generation = generationURL(destination, summary.generation)
    let target = generation.appendingPathComponent("meetings.json")
    let original = try Data(contentsOf: target)
    var corrupted = original
    corrupted[0] = corrupted[0] ^ 0xFF          // same length, different bytes
    try corrupted.write(to: target)

    #expect(try BackupManifest.verify(in: generation, deep: false).isIntact,
            "the cheap check cannot see same-size corruption — that is its documented limit")
    let deep = try BackupManifest.verify(in: generation, deep: true)
    #expect(!deep.isIntact)
    #expect(deep.problems.contains { $0.contains("meetings.json") })
}

@Test("A tampered manifest is caught by its own digest")
func tamperedManifestIsCaught() throws {
    // Not authentication — someone who rewrites the manifest can recompute the digest. It catches
    // a manifest damaged in transit or edited without care, which is the failure that actually
    // happens to a backup folder.
    let (root, source, destination) = try makeLibrary("tampered")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 6, retain: 3)
    let generation = generationURL(destination, summary.generation)
    let manifestURL = generation.appendingPathComponent(BackupManifest.fileName)

    var manifest = try #require(BackupManifest.read(in: generation))
    manifest = BackupManifest(
        generation: manifest.generation,
        createdAtEpoch: manifest.createdAtEpoch,
        files: Array(manifest.files.dropLast()),      // an entry quietly removed
        digest: manifest.digest                        // stale digest left in place
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)

    let result = try BackupManifest.verify(in: generation, deep: false)
    #expect(!result.isIntact)
    #expect(result.problems.contains { $0.lowercased().contains("manifest") })
}

@Test("A generation from a build with no manifest still reads as complete")
func preManifestGenerationIsStillUsable() throws {
    // The append-only rule, one directory over. A generation written before slice D has a
    // completion marker and no manifest, and must not become unrestorable because a newer build
    // wants more evidence — that would turn an improvement into data loss.
    let (root, source, destination) = try makeLibrary("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try BackupCoordinator.backUp(source: source, destination: destination, now: 7, retain: 3)
    let generation = generationURL(destination, summary.generation)
    try FileManager.default.removeItem(at: generation.appendingPathComponent(BackupManifest.fileName))

    #expect(BackupManifest.read(in: generation) == nil)
    let result = try BackupManifest.verify(in: generation, deep: false)
    // Not intact-verified, but explicitly "cannot be verified" rather than "is damaged" — the
    // distinction a restore has to show the user instead of refusing.
    #expect(!result.isIntact)
    #expect(result.isUnverifiable)
    #expect(result.problems.contains { $0.lowercased().contains("no manifest") })
}
