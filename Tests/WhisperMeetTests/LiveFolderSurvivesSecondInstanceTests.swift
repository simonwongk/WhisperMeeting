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
