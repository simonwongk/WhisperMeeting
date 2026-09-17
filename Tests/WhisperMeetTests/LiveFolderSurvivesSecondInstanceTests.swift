import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F255, the end-to-end payoff: the finished recording must still be the one that gets indexed.
//
// The gate's unit tests prove the predicate and that the loop consults it. These prove what the
// ticket is actually about. Without the gate, instance B rebuilds the LIVE folder, indexes its
// partial `meeting-recovered.wav` under the folder's UUID, the folder stops being an orphan, no
// later launch re-scans it, and the complete recording A writes on stop sits beside it
// unreferenced with nothing in the UI that mentions it.
//
// The two halves cannot be one test, and the reason is a property worth stating: leases are
// memoized per resolved library path for the LIFETIME OF THE PROCESS and never evicted
// (`MemoizedLeases`). That is right for the app — one process is one instance — but it means a
// root that once reported `.heldElsewhere` can never report `.held` again in this process, so the
// "rival quits, we relaunch" sequence is not reproducible in-process. Each half therefore gets its
// own root, and neither may reuse the other's.

private func makeLiveFolder(in root: URL, seconds: Int = 1) throws -> URL {
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let folder = recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = [Float](repeating: 0.25, count: 48_000 * seconds)
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try partial.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
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

@Test("A second instance launching mid-capture writes nothing into the live folder")
@MainActor
func secondInstanceLeavesTheLiveFolderAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveFolderGated-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeLiveFolder(in: root)

    let suite = "WhisperMeet.LiveFolderGated.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    // Instance A owns the library. Acquired BEFORE the store is built: a store constructed first
    // would memoize a `.held` handle and this would quietly become a test of the ungated path.
    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.writerLease == .heldElsewhere(realm: "shared"))
    await b.performStartupRecovery()
    // `withExtendedLifetime` takes a synchronous body, so the hold is written out explicitly: the
    // handle releases in `deinit`, and releasing it early would drop the lease mid-startup.
    withExtendedLifetime(instanceA) {}

    #expect(b.store.meetings.isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
    // Both raw tracks are exactly as A left them, still growing as far as this instance knows.
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
    }
    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") == true)
}

@Test("Once the first instance has stopped, its meeting.wav is what gets indexed")
@MainActor
func finishedRecordingIsPreferredOverARebuild() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveFolderFinished-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // The on-disk state after instance A's `stop()` completes: the raw tracks it was writing, plus
    // the finalized recording. Two seconds of WAV against one second of raw track, so a rebuild of
    // those tracks could not be mistaken for the real thing.
    let folder = try makeLiveFolder(in: root, seconds: 1)
    try WAVWriter.wavData(from: [Float](repeating: 0.25, count: 96_000), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))

    let suite = "WhisperMeet.LiveFolderFinished.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    try #require(model.store.mayRebuildInterruptedRecordings)
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meetings.first)
    #expect(meeting.recordingPath.hasSuffix("meeting.wav"))
    #expect(!meeting.recordingPath.contains("recovered"))
    #expect(abs(meeting.duration - 2.0) < 0.05)
    #expect(meeting.recoveryWarning == nil)
    // And no rebuild was written beside it — `finalizedRecording` short-circuits before the mix.
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
}

@Test("A second instance over a clean library says nothing about interrupted recordings")
@MainActor
func secondInstanceDoesNotNagOverACleanLibrary() async throws {
    // The gate's notice tells the user to quit the other copy and relaunch "to finish recovering
    // them". It was appended on the strength of the lease alone, so a second copy opened over a
    // library with nothing to recover said it anyway — on every launch, about nothing.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveFolderCleanNag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Recordings/ exists and is empty: no interrupted folders anywhere.
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )

    let suite = "WhisperMeet.LiveFolderCleanNag.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let instanceA = LibraryWriterLock.acquire(root: root)
    let b = makeModel(root: root, suite: suite)
    try #require(b.store.writerLease == .heldElsewhere(realm: "shared"))
    try #require(try b.store.orphanedRecordings().isEmpty)
    await b.performStartupRecovery()
    withExtendedLifetime(instanceA) {}

    #expect(b.alertMessage?.contains("Another copy of WhisperMeet is open") != true)
}

// MARK: - F279: the recorder that holds no lease at all

/// Appends to a folder's track for as long as it is alive, the way a live capture does.
private final class TrackWriter: @unchecked Sendable {
    private let task: Task<Void, Never>
    init(appendingTo url: URL) {
        task = Task.detached {
            while !Task.isCancelled {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(repeating: 0, count: 4_096))
                    try? handle.close()
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }
    func stop() { task.cancel() }
}

@Test("A folder still being written is left alone even when the lease says go ahead")
@MainActor
func liveFolderIsSkippedDespiteHoldingTheLease() async throws {
    // F255's gate is WIDE OPEN here — this instance holds the lease, exactly as instance C does in
    // F279's sequence after the original holder quit. The only thing standing between the sweep
    // and a live recording is the growth probe.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveProbe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeLiveFolder(in: root)
    let writer = TrackWriter(appendingTo: folder.appendingPathComponent("system-audio.f32"))
    defer { writer.stop() }

    let suite = "WhisperMeet.LiveProbe.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    try #require(model.store.mayRebuildInterruptedRecordings, "the lease gate must be open")

    await model.performStartupRecovery()

    #expect(model.store.meetings.isEmpty, "a live recording must not be indexed as recovered")
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
    #expect(model.alertMessage?.contains("still in progress") == true)
}

@Test("A folder nobody is writing is still rebuilt, seconds after the crash")
@MainActor
func deadFolderIsStillRebuiltImmediately() async throws {
    // The counterpart, and the property a freshness window could not give: a probe that deferred
    // every recovery would break the feature silently, and a crashed recording must come back on
    // the very next launch however soon that is.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeadProbe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeLiveFolder(in: root)

    let suite = "WhisperMeet.DeadProbe.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)

    await model.performStartupRecovery()

    #expect(model.store.meetings.count == 1)
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
}

// MARK: - F283: the capture that is asleep, not dead

/// The on-disk state of a recording the Mac has just slept through: raw tracks that stopped
/// growing, and a sidecar saying an outage began and is expected to end.
private func makeMidOutageFolder(in root: URL, outageBeganAt: Date) throws -> URL {
    let id = UUID()
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let folder = recordings.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = [Float](repeating: 0.25, count: 48_000)
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try partial.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    var session = RecordingSession(id: id, startedAt: outageBeganAt.addingTimeInterval(-60), title: "", markers: [])
    session.outageBeganAt = outageBeganAt
    session.interruptedBySleepAt = outageBeganAt
    try RecordingSessionSidecar.write(session, in: folder)
    return folder
}

@Test("A capture the Mac slept through is not rebuilt, though nothing is growing")
@MainActor
func midOutageFolderIsNotRebuilt() async throws {
    // F283, and both of F279's guards miss it. The tracks are static because nothing is
    // capturing — that is what the gap IS — so the growth probe reads the folder as dead. And the
    // lease gate does not apply: this is a FIRST launch after wake, so it takes the lease
    // legitimately while the recorder holds a valid one and is about to resume.
    //
    // Four minutes is under `defaultMaximumPaddedGap`, so F275 will resume rather than finalize.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MidOutage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeMidOutageFolder(in: root, outageBeganAt: Date().addingTimeInterval(-240))

    let suite = "WhisperMeet.MidOutage.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    try #require(model.store.mayRebuildInterruptedRecordings, "the lease gate must be open")

    await model.performStartupRecovery()

    #expect(model.store.meetings.isEmpty, "a sleeping capture must not be indexed as recovered")
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
    // The raw tracks the live instance is about to append to are untouched.
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
    }
    // Reported, not silent — and worded for a capture that is paused rather than appending.
    #expect(model.alertMessage?.contains("still in progress") == true)
}

@Test("An outage older than the pad cap is rebuilt, so a crash mid-outage is recoverable")
@MainActor
func expiredOutageIsStillRebuilt() async throws {
    // The bound, and it is the half that keeps this from being a new way to lose a recording. Past
    // `defaultMaximumPaddedGap` the restart policy finalizes rather than resuming, so a folder
    // whose outage began longer ago than that is definitively not coming back — and an app that
    // died mid-outage would otherwise leave the flag set forever, which is the defer-forever
    // outcome F279 rejects and worse than the bug F283 closes.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExpiredOutage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeMidOutageFolder(in: root, outageBeganAt: Date().addingTimeInterval(-3_600))

    let suite = "WhisperMeet.ExpiredOutage.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)

    await model.performStartupRecovery()

    #expect(model.store.meetings.count == 1)
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered.wav").path
    ))
}

@Test("A sidecar with no outage recorded does not protect a dead folder")
@MainActor
func sidecarWithoutAnOutageDoesNotDefer() async throws {
    // A crashed recording has a sidecar too — F258 writes one while capturing — so the sidecar's
    // mere existence must not defer recovery. Only a recorded, unexpired outage does.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoOutage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeLiveFolder(in: root)
    try RecordingSessionSidecar.write(
        RecordingSession(id: UUID(), startedAt: Date(), title: "Crashed", markers: []),
        in: folder
    )

    let suite = "WhisperMeet.NoOutage.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)

    await model.performStartupRecovery()

    #expect(model.store.meetings.count == 1)
}
