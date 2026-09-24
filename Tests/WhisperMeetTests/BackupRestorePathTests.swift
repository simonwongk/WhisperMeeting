import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F432 — a restore writes only files a backup of this library can contain, and only inside it.
//
// A restore used to take its file list on trust: `BackupRestorePlan.make` read the paths straight
// out of the generation's manifest (or walked the folder), and `BackupRestore.apply` removed
// whatever sat at `library/<path>` and copied the backup's file over it. Nothing looked at the path.
// The manifest is an integrity check, not a signature — its own header says anyone who can edit a
// generation can recompute it — so a generation planted on a shared drive could name
// `../../LaunchAgents/x.plist` or `Runtime/venv/bin/whisper` and have it written.
//
// Every fixture lives under one temporary root, and the escaping paths are chosen to land inside
// that root and nowhere else, so a regression writes into the test's own folder.

private func makeFixture(_ label: String) throws -> (root: URL, library: URL, generation: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestorePath-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    try Data("index-at-backup-time".utf8).write(to: library.appendingPathComponent("meetings.json"))
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

/// Plants `contents` at `generation/<relativePath>` and lists it in the manifest with a correct
/// size, hash and digest — what someone who can write the backup folder can do, since the manifest
/// authenticates nothing.
private func plant(_ relativePath: String, _ contents: String, in generation: URL) throws {
    let file = generation.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: file)
    let manifest = try #require(BackupManifest.read(in: generation))
    let entry = BackupManifest.Entry(
        relativePath: relativePath,
        size: Int64(contents.utf8.count),
        sha256: try BackupCoordinator.sha256(of: file)
    )
    try BackupManifest(
        generation: manifest.generation,
        createdAtEpoch: manifest.createdAtEpoch,
        files: manifest.files + [entry]
    ).write(to: generation)
}

/// A plan built by hand, standing in for one that reached `apply` by some route other than
/// `make` — the defence in depth has to hold without trusting the planner.
private func handPlan(add: [String] = [], overwrite: [String] = []) -> BackupRestorePlan {
    BackupRestorePlan(
        generation: "1",
        createdAtEpoch: 1,
        wouldOverwrite: overwrite,
        wouldAdd: add,
        notInBackup: [],
        wouldSetAside: [],
        bytesToWrite: 0,
        verification: .init(isIntact: true, isUnverifiable: false, problems: [])
    )
}

/// Everything under `url`, relative, so "nothing was written" is a comparison rather than a hope.
private func tree(_ url: URL) -> Set<String> {
    let base = url.standardizedFileURL.path
    var out: Set<String> = []
    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
    while let item = walker?.nextObject() as? URL {
        out.insert(String(item.standardizedFileURL.path.dropFirst(base.count)))
    }
    return out
}

@Test("A backup whose file list reaches outside the library is refused before it is offered (F432)")
func planRefusesAPathOutsideTheLibrary() throws {
    let (root, library, generation) = try makeFixture("escape-plan")
    defer { try? FileManager.default.removeItem(at: root) }
    // `generation/../escaped.txt` is inside the backup root; `library/../escaped.txt` is `root`.
    try plant("../escaped.txt", "planted", in: generation)

    do {
        let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)
        Issue.record("planned a restore of \(plan.wouldAdd) — it would write outside the library")
    } catch {
        #expect(error.localizedDescription.contains("../escaped.txt"), "\(error.localizedDescription)")
    }
}

@Test("A backup that lists a file no backup contains is refused, even inside the library (F432)")
func planRefusesAPathABackupNeverContains() throws {
    // Inside the library folder, and still not the user's data: the Whisper runtime lives beside
    // the recordings, and replacing it replaces the program the app runs on every transcription.
    let (root, library, generation) = try makeFixture("runtime-plan")
    defer { try? FileManager.default.removeItem(at: root) }
    try plant("Runtime/venv/bin/whisper", "#!/bin/sh\n", in: generation)

    do {
        let plan = try BackupRestorePlan.make(from: generation, into: library, deep: true)
        Issue.record("planned a restore of \(plan.wouldAdd) — it would replace the runtime")
    } catch {
        #expect(error.localizedDescription.contains("Runtime/venv/bin/whisper"), "\(error.localizedDescription)")
    }
}

@Test("An older backup with no manifest restores only what a backup covers (F432)")
func legacyBackupRestoresOnlyLibraryFiles() throws {
    // No manifest, so the file list comes from walking the folder — and a folder holds whatever
    // was put in it. Backups made before F137 copied the whole Application Support directory,
    // runtime included, and Finder leaves `.DS_Store` in any folder someone opened. Those are not
    // refused, because an older backup is still the user's backup; they are simply not restored.
    let (root, library, generation) = try makeFixture("legacy-walk")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: generation.appendingPathComponent(BackupManifest.fileName))
    let runtime = generation.appendingPathComponent("Runtime/venv/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: runtime.appendingPathComponent("whisper"))
    try Data("finder".utf8).write(to: generation.appendingPathComponent(".DS_Store"))
    try Data("index-changed-since".utf8).write(to: library.appendingPathComponent("meetings.json"))

    let plan = try BackupRestorePlan.make(from: generation, into: library, deep: false)
    let restored = plan.wouldOverwrite + plan.wouldAdd
    #expect(!restored.contains("Runtime/venv/bin/whisper"), "\(restored)")
    #expect(!restored.contains(".DS_Store"), "\(restored)")
    #expect(restored.contains("meetings.json"))

    try BackupRestore.apply(plan, from: generation, into: library, acceptingUnverifiedBackup: true)
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("Runtime").path))
    #expect(try Data(contentsOf: library.appendingPathComponent("meetings.json"))
        == Data("index-at-backup-time".utf8))
}

@Test("Applying a plan that escapes the library writes nothing anywhere (F432)")
func applyRefusesAPlanThatEscapes() throws {
    let (root, library, generation) = try makeFixture("escape-apply")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("planted".utf8).write(
        to: generation.deletingLastPathComponent().appendingPathComponent("escaped.txt")
    )
    let libraryBefore = tree(library)

    #expect(throws: (any Error).self) {
        try BackupRestore.apply(handPlan(add: ["../escaped.txt"]), from: generation, into: library)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path),
            "the restore wrote a file outside the library")
    // Refused before the snapshot, too: a refusal that leaves a `.pre-restore-*` behind has
    // already written into the library.
    #expect(tree(library) == libraryBefore)
}

@Test("A restore never removes a directory to put a file in its place (F432)")
func applyNeverReplacesADirectory() throws {
    // `Recordings` is one of the entries a backup covers, so a manifest naming it exactly passes a
    // name check. The apply step removed whatever existed at the target before copying — for this
    // name, the folder holding every recording.
    let (root, library, generation) = try makeFixture("directory")
    defer { try? FileManager.default.removeItem(at: root) }
    let recordings = generation.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.removeItem(at: recordings)
    try Data("not a folder".utf8).write(to: recordings)
    let audio = library.appendingPathComponent("Recordings/meeting-a/meeting.wav")

    #expect(throws: (any Error).self) {
        try BackupRestore.apply(handPlan(add: ["Recordings"]), from: generation, into: library)
    }
    #expect((try? Data(contentsOf: audio)) == Data("audio-a".utf8), "the library's recordings were removed")
}

@Test("A restore does not copy a link out of a backup (F432)")
func applyRefusesALinkInTheBackup() throws {
    // A backup is written from regular files and never contains a link. One that does points
    // wherever its author chose, and a copy of it in the library is a door every later write to
    // that name walks through.
    let (root, library, generation) = try makeFixture("link")
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("elsewhere.txt")
    try Data("someone else's file".utf8).write(to: outside)
    let linked = generation.appendingPathComponent("Recordings/meeting-a/meeting.wav")
    try FileManager.default.removeItem(at: linked)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let audio = library.appendingPathComponent("Recordings/meeting-a/meeting.wav")

    #expect(throws: (any Error).self) {
        try BackupRestore.apply(
            handPlan(overwrite: ["Recordings/meeting-a/meeting.wav"]), from: generation, into: library
        )
    }
    let type = try FileManager.default.attributesOfItem(atPath: audio.path)[.type] as? FileAttributeType
    #expect(type == .typeRegular, "the library's recording was replaced by a link")
    #expect(try Data(contentsOf: audio) == Data("audio-a".utf8))
}
