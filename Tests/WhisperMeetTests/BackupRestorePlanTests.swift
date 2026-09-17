import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice E1 — the dry run, shipped before anything that writes.
//
// A restore copies a backup generation over the user's live library. It is the most dangerous
// operation this app can perform, and slices A-D existed to make the snapshot trustworthy enough
// for it to be safe at all. E1 is the part that makes the danger inspectable: a pure description of
// what a restore WOULD do, including the one thing a naive dry run omits.
//
// That omission is the point of this slice. A plan that lists what would be overwritten and added
// is only two thirds honest — the third set is **what the live library has that the backup does
// not**, which is precisely the user's newer meetings, the ones a restore would silently drop. The
// app knows it and must say it, which is F281's rule in the place it costs most.

private func makeFixture(_ label: String) throws -> (root: URL, library: URL, generation: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestorePlan-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    // The library as it was when the backup was taken.
    try Data("index-v1".utf8).write(to: library.appendingPathComponent("meetings.json"))
    let old = library.appendingPathComponent("Recordings/old-meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("old-audio".utf8).write(to: old.appendingPathComponent("meeting.wav"))

    let summary = try BackupCoordinator.backUp(
        source: library, destination: destination, now: 1, retain: 3
    )
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)
    return (root, library, generation)
}

@Test("A plan names what the backup would overwrite, add, and leave behind")
func planNamesAllThreeSets() throws {
    let (root, library, generation) = try makeFixture("three")
    defer { try? FileManager.default.removeItem(at: root) }

    // Since the backup: the index changed, and a NEWER meeting was recorded that the backup has
    // never seen. That newer meeting is the whole reason a dry run has to exist.
    try Data("index-v2-with-more-meetings".utf8)
        .write(to: library.appendingPathComponent("meetings.json"))
    let newer = library.appendingPathComponent("Recordings/newer-meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
    try Data("newer-audio".utf8).write(to: newer.appendingPathComponent("meeting.wav"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)

    #expect(plan.wouldOverwrite.contains("meetings.json"))
    #expect(plan.wouldOverwrite.contains { $0.hasSuffix("old-meeting/meeting.wav") })
    // The set that matters: present in the library, absent from the backup.
    #expect(plan.notInBackup.contains { $0.hasSuffix("newer-meeting/meeting.wav") })
    #expect(!plan.notInBackup.contains("meetings.json"))
}

@Test("A plan writes nothing at all")
func planIsPure() throws {
    // The safety property, asserted rather than trusted. A dry run that modified anything would be
    // worse than no dry run, because the user ran it precisely to avoid committing.
    let (root, library, generation) = try makeFixture("pure")
    defer { try? FileManager.default.removeItem(at: root) }

    func fingerprint(_ url: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let item = walker?.nextObject() as? URL {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            out[item.path] = Int64(size ?? 0)
        }
        return out
    }
    let libraryBefore = fingerprint(library)
    let generationBefore = fingerprint(generation)

    _ = try BackupRestorePlan.make(from: generation, into: library, deep: true)

    #expect(fingerprint(library) == libraryBefore)
    #expect(fingerprint(generation) == generationBefore)
}

@Test("A plan carries the generation's verification result and refuses to look safe without it")
func planCarriesVerification() throws {
    let (root, library, generation) = try makeFixture("verified")
    defer { try? FileManager.default.removeItem(at: root) }

    let good = try BackupRestorePlan.make(from: generation, into: library, deep: true)
    #expect(good.verification.isIntact)
    #expect(good.isSafeToApply)

    // Damage it at the same size, which only the deep check can see.
    let target = generation.appendingPathComponent("meetings.json")
    var bytes = try Data(contentsOf: target)
    bytes[0] = bytes[0] ^ 0xFF
    try bytes.write(to: target)

    let damaged = try BackupRestorePlan.make(from: generation, into: library, deep: true)
    #expect(!damaged.verification.isIntact)
    #expect(!damaged.isSafeToApply, "a damaged generation must never present as safe to apply")
}

@Test("An unverifiable generation is not safe to apply, and says why")
func unverifiableGenerationIsNotSafe() throws {
    // A pre-slice-D backup can still be restored — refusing would make an improvement into data
    // loss — but not silently. "Cannot be checked" and "is damaged" stay distinguishable all the
    // way to the user, because they call for different decisions.
    let (root, library, generation) = try makeFixture("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: generation.appendingPathComponent(BackupManifest.fileName))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    #expect(plan.verification.isUnverifiable)
    #expect(!plan.isSafeToApply)
    #expect(plan.requiresExplicitOverride)
    // It still describes the restore, because the user may have no better copy.
    #expect(!plan.wouldOverwrite.isEmpty)
}

@Test("A plan totals the bytes it would write")
func planTotalsBytes() throws {
    let (root, library, generation) = try makeFixture("bytes")
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    let expected = Int64("index-v1".utf8.count + "old-audio".utf8.count)
    #expect(plan.bytesToWrite == expected)
}

@Test("Restoring into an empty library adds everything and overwrites nothing")
func emptyLibraryIsAllAdditions() throws {
    let (root, library, generation) = try makeFixture("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    // The F252 shape: the library's index is gone and the user is restoring from a backup.
    try FileManager.default.removeItem(at: library.appendingPathComponent("meetings.json"))
    try FileManager.default.removeItem(at: library.appendingPathComponent("Recordings", isDirectory: true))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    #expect(plan.wouldOverwrite.isEmpty)
    #expect(plan.wouldAdd.count == 2)
    #expect(plan.notInBackup.isEmpty)
    #expect(plan.isSafeToApply)
}
