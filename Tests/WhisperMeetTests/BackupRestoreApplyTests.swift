import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice E2 — the first slice that writes over the user's library.
//
// Everything before this made the snapshot trustworthy and the danger inspectable. This is the
// operation itself, and the properties that matter are not "it copies the files" — that part is
// easy. They are what happens when it does not finish.
//
// A restore that fails halfway has done the worst possible thing: the library is neither the state
// the user had nor the state they asked for. So the pre-restore snapshot is not a nicety, it is the
// only thing that makes the operation attemptable at all, and rollback is tested by making the
// restore fail rather than by trusting that it would work.

private struct ApplyFailure: Error {}

private func makeFixture(_ label: String) throws -> (root: URL, library: URL, generation: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreApply-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    try Data("index-at-backup-time".utf8).write(to: library.appendingPathComponent("meetings.json"))
    try Data("rules-at-backup-time".utf8)
        .write(to: library.appendingPathComponent("replacement-rules.json"))
    let folder = library.appendingPathComponent("Recordings/meeting-a", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio-a".utf8).write(to: folder.appendingPathComponent("meeting.wav"))

    let summary = try BackupCoordinator.backUp(
        source: library, destination: destination, now: 1, retain: 3
    )
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)
    return (root, library, generation)
}

@Test("A restore replaces the library's files with the backup's")
func restoreReplacesTheLibrary() throws {
    let (root, library, generation) = try makeFixture("replace")
    defer { try? FileManager.default.removeItem(at: root) }
    // The library has drifted since the backup.
    try Data("index-changed-since".utf8).write(to: library.appendingPathComponent("meetings.json"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)
    let outcome = try BackupRestore.apply(plan, from: generation, into: library)

    #expect(outcome.restoredFileCount == 3)
    #expect(try Data(contentsOf: library.appendingPathComponent("meetings.json"))
        == Data("index-at-backup-time".utf8))
    #expect(try Data(contentsOf: library.appendingPathComponent("Recordings/meeting-a/meeting.wav"))
        == Data("audio-a".utf8))
}

@Test("The pre-restore snapshot holds what the library had, and survives a success")
func preRestoreSnapshotIsKept() throws {
    // Kept after a SUCCESSFUL restore too, deliberately. "It worked" is the app's opinion; the
    // user may still decide the older snapshot was the wrong one. Deleting their previous state
    // the moment the copy finished would make this operation irreversible at exactly the point it
    // became reversible.
    let (root, library, generation) = try makeFixture("snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("index-changed-since".utf8).write(to: library.appendingPathComponent("meetings.json"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    let outcome = try BackupRestore.apply(plan, from: generation, into: library)

    let snapshot = try #require(outcome.preRestoreSnapshot)
    #expect(try Data(contentsOf: snapshot.appendingPathComponent("meetings.json"))
        == Data("index-changed-since".utf8))
}

@Test("A restore that fails partway puts the library back exactly as it was")
func failedRestoreRollsBack() throws {
    // The property this whole slice rests on, tested by making the copy fail rather than by
    // asserting it would not. A half-restored library is the worst outcome available: neither the
    // state the user had nor the one they asked for.
    let (root, library, generation) = try makeFixture("rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("index-changed-since".utf8).write(to: library.appendingPathComponent("meetings.json"))
    // Excluding the snapshot, which the restore adds on purpose and which is hidden so nothing
    // else in the app sees it.
    func visibleEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: library.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
    let before = try visibleEntries()
    let indexBefore = try Data(contentsOf: library.appendingPathComponent("meetings.json"))
    let rulesBefore = try Data(contentsOf: library.appendingPathComponent("replacement-rules.json"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    var copies = 0
    #expect(throws: (any Error).self) {
        _ = try BackupRestore.apply(plan, from: generation, into: library) { source, target in
            copies += 1
            if copies == 2 { throw ApplyFailure() }   // fails after the first file landed
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    #expect(try visibleEntries() == before)
    #expect(try Data(contentsOf: library.appendingPathComponent("meetings.json")) == indexBefore)
    #expect(try Data(contentsOf: library.appendingPathComponent("replacement-rules.json")) == rulesBefore)
}

@Test("A restore refuses a plan that is not safe to apply")
func unsafePlanIsRefused() throws {
    let (root, library, generation) = try makeFixture("unsafe")
    defer { try? FileManager.default.removeItem(at: root) }
    // Same-size corruption: only the deep check sees it, and it must stop the restore.
    let target = generation.appendingPathComponent("meetings.json")
    var bytes = try Data(contentsOf: target)
    bytes[0] = bytes[0] ^ 0xFF
    try bytes.write(to: target)
    let indexBefore = try Data(contentsOf: library.appendingPathComponent("meetings.json"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)
    try #require(!plan.isSafeToApply)
    #expect(throws: BackupRestoreError.planIsNotSafeToApply) {
        _ = try BackupRestore.apply(plan, from: generation, into: library)
    }
    // Nothing was touched.
    #expect(try Data(contentsOf: library.appendingPathComponent("meetings.json")) == indexBefore)
}

@Test("An unverifiable plan is refused unless the caller overrides explicitly")
func unverifiablePlanNeedsAnOverride() throws {
    let (root, library, generation) = try makeFixture("override")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: generation.appendingPathComponent(BackupManifest.fileName))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    try #require(plan.requiresExplicitOverride)
    // Refused by default: an unchecked backup must not restore just because nothing said no.
    #expect(throws: BackupRestoreError.planIsNotSafeToApply) {
        _ = try BackupRestore.apply(plan, from: generation, into: library)
    }
    // And permitted when the caller says so, because a user with no better copy must not be
    // locked out by an improvement that post-dates their backup.
    let outcome = try BackupRestore.apply(
        plan, from: generation, into: library, acceptingUnverifiedBackup: true
    )
    #expect(outcome.restoredFileCount == 3)
}

@Test("A restore does not delete the library files the backup lacks")
func filesOnlyInTheLibrarySurvive() throws {
    // The plan names them; the restore leaves them alone. Deleting them would turn a copy into a
    // wipe, and the user's newer audio is the thing they would least expect a "restore" to remove.
    let (root, library, generation) = try makeFixture("survive")
    defer { try? FileManager.default.removeItem(at: root) }
    let newer = library.appendingPathComponent("Recordings/meeting-b", isDirectory: true)
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
    try Data("audio-b".utf8).write(to: newer.appendingPathComponent("meeting.wav"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    try #require(plan.notInBackup.contains { $0.hasSuffix("meeting-b/meeting.wav") })
    _ = try BackupRestore.apply(plan, from: generation, into: library)

    #expect(try Data(contentsOf: newer.appendingPathComponent("meeting.wav")) == Data("audio-b".utf8))
}

// F613 — the paths a restore checked are checked again where it copies them.
//
// `apply` validates every source (a regular file, inside the generation), then snapshots every file
// it will overwrite — minutes on a real library — and only then copies. `copyItem` copies a link as a
// link, so someone who can write to a shared backup folder could swap a checked file, or a folder
// above it, for a link during the snapshot, and the link — or a file from wherever it pointed —
// landed in the library: F432's escape, by a later door. The copy seam is the swap here.
@Test("A source swapped for a link after the check is caught after its copy, and the restore rolls back (F613)")
func aSourceSwappedForALinkRollsTheRestoreBack() throws {
    let (root, library, generation) = try makeFixture("swap-link")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("index-changed-since".utf8).write(to: library.appendingPathComponent("meetings.json"))
    let outside = root.appendingPathComponent("outside.json")
    try Data("someone else's file".utf8).write(to: outside)
    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)

    #expect(throws: BackupRestoreError.unrestorablePath("meetings.json")) {
        try BackupRestore.apply(plan, from: generation, into: library, copy: { source, target in
            if source.lastPathComponent == "meetings.json" {
                // Between the check and this copy, the checked file becomes a link.
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            }
            try FileManager.default.copyItem(at: source, to: target)
        })
    }

    let index = library.appendingPathComponent("meetings.json")
    let type = try FileManager.default.attributesOfItem(atPath: index.path)[.type] as? FileAttributeType
    #expect(type == .typeRegular, "a link was left in the library")
    #expect(try Data(contentsOf: index) == Data("index-changed-since".utf8), "the library was not put back")
}

@Test("A folder above a later source swapped for a link mid-restore is refused before that file is copied (F613)")
func aFolderSwappedForALinkIsRefusedBeforeItsCopy() throws {
    // Two recordings, so one is copied while the other's folder in the backup is swapped: the plan
    // copies in sorted order, `Recordings/a/…` before `Recordings/b/…`.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreApply-swap-folder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for name in ["a", "b"] {
        let folder = library.appendingPathComponent("Recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio-\(name)".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    }
    try Data("index-at-backup-time".utf8).write(to: library.appendingPathComponent("meetings.json"))
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try Data("someone else's audio".utf8).write(to: elsewhere.appendingPathComponent("meeting.wav"))
    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)
    let first = "Recordings/a/meeting.wav", second = "Recordings/b/meeting.wav"
    let order = plan.wouldOverwrite + plan.wouldAdd
    try #require(order.firstIndex(of: first)! < order.firstIndex(of: second)!, "fixture: \(order)")
    var copied: [String] = []

    #expect(throws: BackupRestoreError.unrestorablePath(second)) {
        try BackupRestore.apply(plan, from: generation, into: library, copy: { source, target in
            let path = String(source.path.dropFirst(generation.path.count + 1))
            copied.append(path)
            if path == first {
                // While the first recording is copied, the second's folder in the backup becomes a link.
                let folder = generation.appendingPathComponent("Recordings/b", isDirectory: true)
                try FileManager.default.removeItem(at: folder)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
            }
            try FileManager.default.copyItem(at: source, to: target)
        })
    }

    #expect(!copied.contains(second), "a file was copied through the swapped folder: \(copied)")
    #expect(try Data(contentsOf: library.appendingPathComponent(second)) == Data("audio-b".utf8))
    #expect(try Data(contentsOf: library.appendingPathComponent(first)) == Data("audio-a".utf8))
}
