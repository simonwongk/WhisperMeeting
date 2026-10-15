import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F936 — a finished recording whose index save never happened, beside an index on disk that is `[]`.
//
// A crash or power loss between Stop's finalize (`meeting.wav` written) and its index save, on a
// library whose index is `[]` (this or another copy deleted its last meeting), left one finished
// folder beside an empty index, and the next launch read that as the wipe shape (`.suspectEmpty`):
// read-only, with a restore — which brings back the deleted meeting — as the way out. The folder's
// `capture.lock` (F297) tells the two apart: a clean Stop removes it only once the meeting is
// indexed, so a finished folder still holding its lock file was never indexed by its writer, and
// the launch leaves it to the orphan sweep, which adopts it. A finished folder with no lock file —
// an older build's, or one whose meeting WAS indexed and then wiped — still counts.
//
// The quit case (the review of Wave 5 lane Y, P-Y8): a Stop whose save lost twice is held by the
// banner, out of the index; the lock file used to be removed as if the meeting were indexed, so
// quitting then opened read-only too. It is kept now, as the failed-finalize path keeps it.

private func libraryRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F936-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// The index exactly as a delete of the last meeting leaves it: valid JSON, zero records.
private func writeEmptyIndex(in root: URL) throws {
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
}

/// A complete WAV: header plus the payload it declares, so recovery reads it as finished.
private func finishedWAV(seconds: UInt32 = 1) -> Data {
    let dataByteCount = 48_000 * 2 * seconds
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    return wav
}

/// `Recordings/<id>/` as a Stop leaves it after `meeting.wav` is written and before the index save:
/// the mixed WAV, the manifest, and — when `lockFile` — the 0-byte `capture.lock` the capture held,
/// now free because its process is gone.
@discardableResult
private func writeFinishedFolder(in root: URL, lockFile: Bool) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try finishedWAV().write(to: folder.appendingPathComponent("meeting.wav"))
    try Data(#"{"systemAudio":{},"microphoneAudio":{}}"#.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
    if lockFile { try Data().write(to: folder.appendingPathComponent(RecordingCaptureLock.filename)) }
    return (id, folder)
}

@MainActor
private func makeModel(root: URL) throws -> (AppModel, () -> Void) {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    model.crashReportsSince = { _ in [] }
    return (model, { defaults.removePersistentDomain(forName: suite) })
}

@MainActor
@Test("A finished folder still holding its free capture lock beside an empty index opens writable, and the sweep adopts it (F936)")
func aFinishedFolderWithItsLockBesideAnEmptyIndexIsAdoptedNotTakenForAWipe() async throws {
    let root = try libraryRoot("lock")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    let (id, folder) = try writeFinishedFolder(in: root, lockFile: true)

    let (model, cleanup) = try makeModel(root: root)
    defer { cleanup() }
    #expect(model.store.health == .complete, "a recording nobody indexed yet was taken for a wiped meeting: \(model.store.health)")
    #expect(!model.store.isDegraded)

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the orphan sweep did not adopt the finished recording")
    #expect(meeting.recordingPath.hasSuffix("meeting.wav"), "\(meeting.recordingPath)")
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) != nil, "the adopted meeting never reached the index")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingCaptureLock.filename).path),
            "the lock file stays after the meeting is indexed")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.wav").path))
}

@MainActor
@Test("The same finished folder without a lock file beside an empty index still opens read-only (F936, F187)")
func aFinishedFolderWithoutALockBesideAnEmptyIndexIsStillAWipe() throws {
    let root = try libraryRoot("nolock")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    try writeFinishedFolder(in: root, lockFile: false)

    let store = MeetingStore(rootDirectory: root)

    #expect(store.health == .suspectEmpty(recordingFolderCount: 1), "\(store.health)")
    #expect(store.isDegraded)
}

@MainActor
@Test("Two finished folders, one with its lock and one without, beside an empty index: the one without still counts (F936)")
func onlyTheFoldersWithoutALockCountAgainstAnEmptyIndex() throws {
    let root = try libraryRoot("mixed")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEmptyIndex(in: root)
    try writeFinishedFolder(in: root, lockFile: true)
    try writeFinishedFolder(in: root, lockFile: false)

    let store = MeetingStore(rootDirectory: root)

    #expect(store.health == .suspectEmpty(recordingFolderCount: 1), "\(store.health)")
}

/// The quit case (P-Y8). Another copy empties the index before this window's Stop saves, and again
/// before the recovery's re-save, so the banner holds the just-stopped recording (`unsavedNew`, F667).
/// Quitting then — here, opening a second store over the same root — must not open read-only: the
/// folder keeps its lock file, because its meeting was never indexed.
@MainActor
@Test("A Stop whose save the banner holds keeps its lock file, so a quit before the answer does not open the library read-only (F936)")
func aStopHeldByTheBannerKeepsItsLockFile() async throws {
    let root = try libraryRoot("quit")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, cleanup) = try makeModel(root: root)
    defer { cleanup() }
    let store = model.store
    let standup = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))

    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let folder = store.recordingDirectoryURL(for: id)
    try model.recorder.beginTestTrackSession(in: folder)
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 0, microphoneStart: 0)
    // The other copy deletes its last meeting before the Stop's save, and saves again before the re-save.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count }
    )
    var seen = try rival.load()
    _ = try rival.save([], expecting: seen?.token)
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 {
            seen = try? rival.load()
            _ = try? rival.save([MeetingRecord(title: "The other copy's", status: .recorded)], expecting: seen?.token)
        }
    }

    _ = await model.stopRecording(title: model.recordingTitle)
    store.beforeIndexSaveForTesting = nil

    let offer = try #require(store.conflictOffer, "fixture: the Stop's saves should have lost twice")
    try #require(offer.unsavedNew.contains { $0.id == id }, "fixture: the banner should hold the recording: \(offer.message)")
    try #require(store.meeting(id: id) == nil, "fixture: the recording is held out of the list")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingCaptureLock.filename).path),
            "the lock file was removed for a meeting that was never indexed")

    // The other copy then empties its index again, and this window quits without answering: the
    // next launch over this library.
    seen = try rival.load()
    _ = try rival.save([], expecting: seen?.token)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health == .complete, "the next launch took the held recording for a wiped meeting: \(reopened.health)")
}

/// The rule above trusts the lock file to mean "never indexed", so every path that indexes a meeting
/// must remove it (the review of Wave 7 lane Y, P1). The banner's answer is such a path: a Stop it
/// held is indexed by Keep My Edit or Use the Other Copy (`saveBack`), and the file used to stay —
/// forever, in an indexed folder — so a later wipe of the index beside it opened writable and the
/// sweep replaced the meeting's index entry with a "Recovered Meeting".
@MainActor
@Test("A held Stop indexed by the banner's answer loses its lock file, so a later wipe beside it is still seen (F936)")
func aHeldStopIndexedByTheBannersAnswerLosesItsLockFile() async throws {
    let root = try libraryRoot("answered")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, cleanup) = try makeModel(root: root)
    defer { cleanup() }
    let store = model.store
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed))
    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let folder = store.recordingDirectoryURL(for: id)
    try model.recorder.beginTestTrackSession(in: folder)
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 0, microphoneStart: 0)
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count }
    )
    var seen = try rival.load()
    _ = try rival.save([], expecting: seen?.token)
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 {
            seen = try? rival.load()
            _ = try? rival.save([MeetingRecord(title: "The other copy's", status: .recorded)], expecting: seen?.token)
        }
    }
    _ = await model.stopRecording(title: model.recordingTitle)
    store.beforeIndexSaveForTesting = nil
    try #require(store.conflictOffer?.unsavedNew.contains { $0.id == id } == true, "fixture: the banner holds the Stop")
    let lock = folder.appendingPathComponent(RecordingCaptureLock.filename).path
    try #require(FileManager.default.fileExists(atPath: lock), "fixture: the held Stop keeps its lock file")

    store.keepConflictedEdit()

    try #require(MeetingStore(rootDirectory: root).meeting(id: id) != nil, "fixture: Keep did not index the held Stop")
    #expect(!FileManager.default.fileExists(atPath: lock), "the indexed folder kept its lock file")
    // A later wipe of the index (the 2026-08-14 shape) beside this one indexed recording.
    seen = try rival.load()
    _ = try rival.save([], expecting: seen?.token)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health == .suspectEmpty(recordingFolderCount: 1),
            "an index wiped beside an indexed recording opened writable: \(reopened.health)")
}

/// A lock file left in an indexed folder by a build that did not remove it — or by a crash between
/// the index save and the removal — is removed by the next launch's sweep, so it hides nothing after
/// one clean launch. A lock the sweep cannot take (a writer alive in that folder) is left alone.
@MainActor
@Test("The sweep removes a free lock file left in an indexed folder, so the next wipe beside it is seen (F936)")
func theSweepRemovesAStaleLockFromAnIndexedFolder() async throws {
    let root = try libraryRoot("heal")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try writeFinishedFolder(in: root, lockFile: true)
    let seeded = MeetingStore(rootDirectory: root)
    seeded.upsert(MeetingRecord(id: id, title: "Indexed, lock left behind",
                                recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded))
    try #require(seeded.health == .complete)
    let lock = folder.appendingPathComponent(RecordingCaptureLock.filename).path

    let (model, cleanup) = try makeModel(root: root)
    defer { cleanup() }
    await model.performStartupRecovery()

    #expect(!FileManager.default.fileExists(atPath: lock), "the sweep left a free lock in an indexed folder")
    #expect(model.store.meeting(id: id)?.title == "Indexed, lock left behind", "the sweep touched the indexed meeting")
    // Another copy then wipes the index (the 2026-08-14 shape): seen, now that the folder counts again.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save([], expecting: seen?.token)
    #expect(MeetingStore(rootDirectory: root).health == .suspectEmpty(recordingFolderCount: 1))
}

@MainActor
@Test("The sweep leaves a lock file whose writer is alive, whether or not its meeting is indexed (F936, F297)")
func theSweepLeavesAHeldLockAlone() async throws {
    let root = try libraryRoot("held")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try writeFinishedFolder(in: root, lockFile: false)
    let seeded = MeetingStore(rootDirectory: root)
    seeded.upsert(MeetingRecord(id: id, title: "Being written", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded))
    let writer = try #require(RecordingCaptureLock.acquire(in: folder), "fixture: could not take the folder's lock")
    defer { writer.release(removingFile: true) }
    let lock = folder.appendingPathComponent(RecordingCaptureLock.filename).path

    let (model, cleanup) = try makeModel(root: root)
    defer { cleanup() }
    await model.performStartupRecovery()

    #expect(FileManager.default.fileExists(atPath: lock), "the sweep removed a lock a live writer holds")
    #expect(RecordingCaptureLock.probe(in: folder) == .heldByLiveWriter)
}
