import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F297 — the folder F255 left waiting: crashed in one instance, unrecoverable for as long as any
// other copy of the app is open. With the per-folder capture lock the sweep can tell that folder
// apart from a live one, and rebuild it under a rival lease.
//
// Same recipe as the F255 tests, for the same reason: the library lease is memoized per root for
// the life of the process, so a root that once reported `.heldElsewhere` never reports `.held`
// again. Every test gets its own root. And the rival is acquired BEFORE the store is built, or the
// store memoizes `.held` and the test quietly becomes one of the ungated path.

private func makeDeadLookingFolder(in root: URL) throws -> URL {
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let folder = recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = [Float](repeating: 0.25, count: 48_000)
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try partial.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    return folder
}

/// A folder whose capture took the lock and then died: the file is there and nobody holds it.
private func makeCrashedFolder(in root: URL) throws -> URL {
    let folder = try makeDeadLookingFolder(in: root)
    let writer = try #require(RecordingCaptureLock.acquire(in: folder))
    writer.release()   // the kernel does this for a dead process
    return folder
}

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

@Test("A crashed recording is rebuilt while another copy of the app is open (F297)")
@MainActor
func crashedFolderIsRebuiltUnderARivalLease() async throws {
    // The ticket's four steps: A idle with the lease, B records and crashes, B relaunches with A
    // still open. Before F297, B refused to rebuild its own recording and told the user to quit a
    // copy they had no reason to think was involved.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashedUnderRival-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeCrashedFolder(in: root)
    let suite = "WhisperMeet.CrashedUnderRival.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.writerLease == .heldElsewhere(realm: "shared"))
    await b.performStartupRecovery()
    withExtendedLifetime(instanceA) {}

    #expect(b.store.meetings.count == 1, "the crashed recording should be back in history")
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
    // Nothing was refused for the lease, so the notice that names the other copy must not appear:
    // it told the user to quit something for a reason they could not see.
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") != true, "\(b.alertMessage ?? "")")
    // And the folder no longer looks crashed to the next launch.
    #expect(RecordingCaptureLock.probe(in: folder) == .noLockFile)
}

@Test("A folder from before the lock existed is still deferred under a rival lease (F297)")
@MainActor
func unlockedFolderStillWaitsUnderARivalLease() async throws {
    // F255's rule is unchanged where the lock has nothing to say. One crashed folder with a lock,
    // one dead-looking folder without: the first is rebuilt, the second is left for a launch with
    // no rival, and the notice appears because something WAS refused.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MixedUnderRival-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let crashed = try makeCrashedFolder(in: root)
    let unknown = try makeDeadLookingFolder(in: root)
    let suite = "WhisperMeet.MixedUnderRival.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.writerLease == .heldElsewhere(realm: "shared"))
    await b.performStartupRecovery()
    withExtendedLifetime(instanceA) {}

    #expect(b.store.meetings.count == 1)
    #expect(FileManager.default.fileExists(atPath: crashed.appendingPathComponent("meeting-recovered.wav").path))
    #expect(!FileManager.default.fileExists(atPath: unknown.appendingPathComponent("meeting-recovered.wav").path))
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") == true)
}

@Test("A folder whose writer holds the lock is refused even when the lease says go ahead (F297)")
@MainActor
func heldLockRefusesRebuildDespiteTheLease() async throws {
    // The refusal F255 could not make. This instance holds the lease — the rival has quit, or
    // never took it — and the folder is not growing within the probe's 400 ms. Only the lock says
    // a writer is alive, and it is enough.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeldDespiteLease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeDeadLookingFolder(in: root)
    let writer = try #require(RecordingCaptureLock.acquire(in: folder))
    let suite = "WhisperMeet.HeldDespiteLease.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let model = makeModel(root: root, suite: suite)
    try #require(model.store.mayRebuildInterruptedRecordings)
    await model.performStartupRecovery()
    withExtendedLifetime(writer) {}

    #expect(model.store.meetings.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting-recovered.wav").path))
    #expect(model.alertMessage?.contains("still in progress") == true, "\(model.alertMessage ?? "")")
}

// MARK: - the writer's side

@MainActor
private func makeRecordingModel() throws -> (AppModel, URL, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptureLockWriter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F297.writer.\(UUID().uuidString)"
    let recorder = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: recorder,
        defaults: UserDefaults(suiteName: suite)!,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    return (model, root, suite)
}

@Test("A recording holds its folder's lock from start to finish, and no longer afterwards (F297)")
@MainActor
func recordingHoldsTheCaptureLock() async throws {
    // Through `startRecording` with the engine's injection seam standing in for the microphone —
    // the writer side is the half that makes every other test here mean something, and a lock
    // nothing takes is F306's shape.
    let (model, root, suite) = try makeRecordingModel()
    defer {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID, "the recording did not start")
    let directory = model.store.recordingDirectoryURL(for: id)
    #expect(RecordingCaptureLock.probe(in: directory) == .heldByLiveWriter)

    await model.cancelRecording()
    // Cancel removes the folder; what matters is that nothing is still held on it.
    #expect(model.activeMeetingID == nil)
    #expect(RecordingCaptureLock.probe(in: directory) == .noLockFile)
}

// MARK: - F188: the rival that quit

@Test("The lease refresh lets a second sweep rebuild once the rival has quit — driven by a test-only reset, not a production caller (F188, F407)")
@MainActor
func recoveryRebuildsAfterTheRivalQuitsWithoutRelaunching() async throws {
    // What this tests, precisely: `store.refreshWriterLease()` re-asks the kernel rather than
    // trusting the lease `MeetingStore.init` sampled, so a SECOND `performStartupRecovery()` sweep
    // sees a rival that has since quit. The second sweep here is produced by
    // `resetStartupRecoveryForTesting()`, a `DEBUG`-only seam.
    //
    // What this does NOT test, and what an earlier version of this comment claimed it did: that a
    // user reaches a second sweep over a HEALTHY library like this one without relaunching. They
    // do not. The only two production callers that reset `didPerformStartupRecovery` are
    // `recoverLibrary` and `rebuildLibraryFromFolders`, and both are reached only through
    // `requestLibraryRecovery()`'s `guard store.isDegraded` — refused outright for a library this
    // fixture never damages. So an instance that launches healthy, is told to quit a rival, and
    // whose rival then quits, has no in-session way back to a second sweep; relaunching is still
    // the only remedy for exactly this case. F407 was filed because this comment used to say the
    // opposite ("does NOT relaunch… which this change makes unnecessary").
    //
    // The sequence that IS reachable in production — a DEGRADED launch, the rival's lease, then
    // Restore — is `degradedLaunchThenRestoreRebuildsAfterTheRivalQuits` below, driven entirely
    // through `rebuildLibraryFromFolders(confirmed: true)` with no test-only reset at all.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RivalQuitThenRecover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeDeadLookingFolder(in: root)
    let suite = "WhisperMeet.RivalQuitThenRecover.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.writerLease == .heldElsewhere(realm: "shared"))
    await b.performStartupRecovery()
    #expect(b.store.meetings.isEmpty)
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") == true)

    // The DEBUG-only seam standing in for whatever would reset the flag in production — which, for
    // a healthy library, is nothing (see above).
    instanceA.release()
    b.resetStartupRecoveryForTesting()
    b.alertMessage = nil
    await b.performStartupRecovery()

    #expect(b.store.writerLease == .held(realm: "shared"))
    #expect(b.store.meetings.count == 1, "the recording should be back once the lease is re-asked")
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") != true, "\(b.alertMessage ?? "")")
}

/// A degraded library — broken `meetings.json`/`meetings.backup.json`, no retained generation, so
/// `FolderRebuild` (F252's dead end) is the only in-app way back — with one finalized recording
/// folder for the rebuild to offer, and one dead-looking, unindexed folder for the recovery sweep
/// the rebuild re-triggers to find. Reuses `makeDeadLookingFolder` for the second folder.
@MainActor
private func makeDeadEndLibraryWithInterruption(in root: URL) throws -> URL {
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    let finalizedID = UUID()
    let finalizedFolder = root
        .appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent(finalizedID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: finalizedFolder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)
        .write(to: finalizedFolder.appendingPathComponent("meeting.wav"))
    try Data("# Standup\n\nbody\n".utf8).write(to: finalizedFolder.appendingPathComponent("notes.md"))
    return try makeDeadLookingFolder(in: root)
}

@Test("The reachable rival sequence: a degraded launch, the rival quits, then Restore rebuilds without the notice (F407)")
@MainActor
func degradedLaunchThenRestoreRebuildsAfterTheRivalQuits() async throws {
    // F407 part 2: the sequence production actually allows — a degraded launch with a live rival,
    // the rival quitting, then the user pressing Restore — had no test. This drives it entirely
    // through real callers: `requestLibraryRecovery()` and `rebuildLibraryFromFolders(confirmed:)`,
    // never `resetStartupRecoveryForTesting()`.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeadEndUnderRival-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let interrupted = try makeDeadEndLibraryWithInterruption(in: root)
    let suite = "WhisperMeet.DeadEndUnderRival.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    // The rival holds the lease BEFORE B is constructed, exactly as the F297 fixtures require.
    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.isDegraded, "the fixture must be the read-only dead end")
    try #require(try b.store.indexGenerations().isEmpty, "the fixture must have nothing to restore")
    #expect(b.store.writerLease == .heldElsewhere(realm: "shared"))

    // Launch #1: degraded, so `performStartupRecovery` takes the early return BEFORE the lease or
    // the orphan sweep is even reached (AppModel.swift's `if store.isDegraded { …; return }`) — the
    // read-only notice appears, and the rival notice, which lives past that return, does not.
    await b.performStartupRecovery()
    #expect(b.alertMessage?.contains("read-only mode") == true, "\(b.alertMessage ?? "")")
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") != true, "\(b.alertMessage ?? "")")

    // The user does what F289 offers: with nothing to restore, Recover Library proposes the folder
    // rebuild instead of the dead end.
    b.requestLibraryRecovery()
    let proposal = try #require(b.pendingFolderRebuild, "the rebuild offer should have appeared")
    #expect(proposal.isWorthApplying)
    #expect(proposal.deferredToRecovery == 1, "the interrupted folder must be deferred, not indexed as a stub meeting")

    // The rival quits before the user presses Restore.
    instanceA.release()

    // Restore. `rebuildLibraryFromFolders` is the one production caller that resets
    // `didPerformStartupRecovery` and queues a second sweep — no test-only seam anywhere above.
    b.rebuildLibraryFromFolders(confirmed: true)
    #expect(!b.store.isDegraded, "the rebuild must return the library to a writable state")

    // The second sweep the rebuild just queued as a fire-and-forget `Task`. Calling it here
    // directly is deterministic rather than a race with that Task: `didPerformStartupRecovery` was
    // reset synchronously above and nothing has suspended yet to let the queued Task run first, so
    // this call is the one whose body executes; the queued Task later finds the flag already set
    // and no-ops, which is the idempotence `recoverLibrary`'s doc comment already relies on.
    await b.performStartupRecovery()

    #expect(b.store.writerLease == .held(realm: "shared"), "the lease should have been re-asked, not left stale")
    #expect(FileManager.default.fileExists(
        atPath: interrupted.appendingPathComponent("meeting-recovered.wav").path
    ), "the interrupted folder should be rebuilt now that nothing refuses it")
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") != true, "\(b.alertMessage ?? "")")
}
