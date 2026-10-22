import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — Shrink through the app-level call, over a real temp library. The encoder and decoder are
// seams (F47), so each test can make the encode succeed, fail or lie about its length. The order is
// the claim: nothing original is removed until the index names the new file.

/// Records that a `@Sendable` seam ran. A captured `var` cannot be mutated from one.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func set() { lock.lock(); called = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return called }
}

@MainActor
private struct Fixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL
    /// Where Shrink's removals go (F1040): never the user's Trash.
    let trash: ShrinkTestTrash

    // 60 s, so the predicted output (246 KB) is well under a quarter of these files and the
    // worth-it rule passes; an hour's prediction (14.8 MB) would make them "already compact".
    // The recording is a real WAV and the tracks have a matching manifest: zero-filled stand-ins
    // read as damaged to Verify Library and Rebuild Audio, and Shrink rightly refuses those.
    init(recordingName: String = "meeting.wav", duration: TimeInterval = 60, wavSeconds: Double = 60,
         recordingPath: String? = nil, extraFiles: [String: Int] = [:], failingTrash: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkFlow-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeCapture(in: folder, recordingName: recordingName, wavSeconds: wavSeconds)
        for (name, size) in extraFiles { try Data(count: size).write(to: folder.appendingPathComponent(name)) }
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        trash = try ShrinkTestTrash(in: root, failing: failingTrash)
        model.trashForShrink = trash.seam
        model.store.upsert(MeetingRecord(
            id: id, title: "Weekly sync", duration: duration,
            recordingPath: recordingPath ?? "Recordings/\(id.uuidString)/\(recordingName)",
            status: .completed, transcriptText: "Hi."))
        // Seams: a fake encode writes a small file; lengths and levels (F801) agree unless a test says
        // otherwise. The one decode seam answers for the copy and the original alike.
        model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }
        model.decodeForShrink = { _ in DecodedAudio.Decoded(duration: wavSeconds, level: 0.1) }
        model.declaredDurationForShrink = { _ in wavSeconds }
        model.availableBytesForShrink = { _ in .max }
        // F1004: the stand-in files AVFoundation cannot read are decoded by the installed ffmpeg to check their
        // channels; here each decodes to one channel, which has nothing to cancel against.
        model.decodeUnreadableForShrink = { _, output in
            try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: output)
        }
    }

    /// A finished capture: a real WAV (or, for a shrunk recording, opaque bytes), both raw tracks
    /// and a manifest whose frame counts match them, plus two files Shrink must keep.
    static func writeCapture(in folder: URL, recordingName: String, wavSeconds: Double) throws {
        let trackBytes = 6_000_000
        if recordingName.hasSuffix(".wav") {
            try WAVWriter.wavData(from: [Float](repeating: 0.1, count: Int(wavSeconds * 48_000)), sampleRate: 48_000)
                .write(to: folder.appendingPathComponent(recordingName))
        } else {
            try Data(count: 15_000).write(to: folder.appendingPathComponent(recordingName))
        }
        for name in ["system-audio.f32", "microphone-audio.f32"] {
            try Data(count: trackBytes).write(to: folder.appendingPathComponent(name))
        }
        let frames = trackBytes / 4
        try Data("""
            {"systemAudio":{"file":"system-audio.f32","frameCount":\(frames)},
             "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(frames)}}
            """.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
        try Data(count: 50).write(to: folder.appendingPathComponent("notes.md"))
        try Data(count: 20).write(to: folder.appendingPathComponent("diarization.json"))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// What `meetings.json` says on disk, read without opening a second `MeetingStore`.
    func persistedPath() -> String? {
        let reader = BackupJSONStore<[MeetingRecord]>(
            primaryURL: root.appendingPathComponent("meetings.json"),
            backupURL: root.appendingPathComponent("meetings.backup.json"),
            writer: "test-reader", recordCount: { $0.count })
        return (try? reader.load())??.value.first { $0.id == id }?.recordingPath
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("Shrink replaces the audio, keeps the rest, and the index names the new file (F795)")
@MainActor
func shrinkReplacesTheAudioAndKeepsEverythingElse() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    #expect(f.exists("meeting.m4a"))
    for gone in ["meeting.wav", "system-audio.f32", "microphone-audio.f32", "source-tracks.json"] {
        #expect(!f.exists(gone), "\(gone) should be removed")
    }
    #expect(f.exists("notes.md") && f.exists("diarization.json"))
    #expect(f.persistedPath()?.hasSuffix("/meeting.m4a") == true)
    #expect(f.model.alertMessage?.contains("Shrunk") == true)
}

@Test("Nothing original is removed until the saved index names the new file (F795)")
@MainActor
func shrinkSavesTheIndexBeforeRemovingAnything() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    var pathAtFirstRemoval: String?
    f.model.willRemoveForShrink = { _ in
        if pathAtFirstRemoval == nil { pathAtFirstRemoval = f.persistedPath() }
    }
    await f.shrink()
    #expect(pathAtFirstRemoval?.hasSuffix("/meeting.m4a") == true)
}

@Test("A failed index save keeps every original and leaves no new file (F795)")
@MainActor
func shrinkFailedSaveKeepsEverything() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])
    // Another copy commits first, so this session's save loses the compare-and-swap.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: f.root.appendingPathComponent("meetings.json"),
        backupURL: f.root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count })
    let existing = try rival.load()
    // A real change, as SynchronousMutatorRaceTests' rivals make: the other copy retitles it.
    let retitled = (existing?.value ?? []).map { record -> MeetingRecord in
        var copy = record; copy.title = "Retitled by the other copy"; return copy
    }
    _ = try rival.save(retitled, expecting: existing?.token)
    await f.model.performShrink(confirmed: true)?.value
    for kept in ["meeting.wav", "system-audio.f32", "microphone-audio.f32", "source-tracks.json"] {
        #expect(f.exists(kept), "\(kept) must survive a failed save")
    }
    // The verified copy is LEFT, not removed (review finding 1): after a lost race, the other copy's
    // index may already name meeting.m4a, and removing it then leaves the meeting with no audio.
    // An unreferenced verified copy is harmless, and the next shrink replaces it.
    #expect(f.exists("meeting.m4a"))
    // It was the save that refused, not an earlier guard: the outcome is the failure sentence.
    #expect(f.model.alertMessage?.contains("could not be shrunk, and nothing was removed") == true,
            "\(f.model.alertMessage ?? "nil")")
    #expect(f.model.alertMessage?.contains("compressed copy was left") == true, "\(f.model.alertMessage ?? "nil")")
}

@Test("A length mismatch or a failed encode changes nothing and leaves no temp files (F795)")
@MainActor
func shrinkVerificationFailureChangesNothing() async throws {
    for mode in ["mismatch", "throws"] {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if mode == "mismatch" {
            f.model.decodeForShrink = { _ in DecodedAudio.Decoded(duration: 1_800, level: 0.1) }
        } else {
            f.model.encodeForShrink = { _, _, _ in throw AudioTranscoderError.transcodeFailed("boom") }
        }
        await f.shrink()
        #expect(f.exists("meeting.wav") && f.exists("system-audio.f32"), "\(mode)")
        #expect(!f.exists("meeting.m4a"), "\(mode)")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: f.folder.path).filter { $0.hasPrefix(".shrink-") }
        #expect(hidden.isEmpty, "\(mode): \(hidden)")
        #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/meeting.wav") == true)
    }
}

@Test("A refused shrink touches nothing: not its own folder, or a length that can't be read (F795)")
@MainActor
func shrinkRefusalsTouchNothing() async throws {
    // Review Focus 3: a recording outside its own Recordings/<id>/ folder.
    // The record's file must EXIST outside the folder, or it is refused as missing and the
    // own-folder guards are never reached (review finding 6: the first version was inert).
    let odd = try Fixture(recordingPath: "Elsewhere/meeting.wav")
    defer { try? FileManager.default.removeItem(at: odd.root) }
    let elsewhere = odd.root.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000 * 60), sampleRate: 48_000)
        .write(to: elsewhere.appendingPathComponent("meeting.wav"))
    let encoded = CallFlag()
    odd.model.encodeForShrink = { _, _, _ in encoded.set() }
    await odd.model.refreshStorage(ids: [odd.id])
    #expect(odd.model.shrinkUnavailability(for: try #require(odd.model.store.meeting(id: odd.id)))
            == .unsupportedRecording)
    await odd.shrink()
    #expect(!encoded.value && odd.exists("system-audio.f32"))
    #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("meeting.wav").path))
    // Review Focus 5: no length anywhere, so the encoder never runs.
    let unknown = try Fixture(duration: 0)
    defer { try? FileManager.default.removeItem(at: unknown.root) }
    unknown.model.declaredDurationForShrink = { _ in nil }
    unknown.model.encodeForShrink = { _, _, _ in encoded.set() }
    await unknown.model.refreshStorage(ids: [unknown.id])
    #expect(unknown.model.shrinkUnavailability(for: try #require(unknown.model.store.meeting(id: unknown.id)))
            == .cannotMeasureLength)
    await unknown.shrink()
    #expect(!encoded.value && unknown.exists("meeting.wav"))
}

@Test("A stale unreferenced meeting.m4a is replaced, not reported as existing (F795)")
@MainActor
func shrinkReplacesAStaleOutputFile() async throws {
    // Review Focus 4: left by an earlier failed save whose cleanup also failed.
    let f = try Fixture(extraFiles: ["meeting.m4a": 7]); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let size = try f.folder.appendingPathComponent("meeting.m4a").resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(size == 15_000)
    #expect(!f.exists("meeting.wav"))
}

@Test("A resumed shrink removes leftovers without encoding again (F795)")
@MainActor
func shrinkResumeRemovesLeftoversOnly() async throws {
    let f = try Fixture(recordingName: "meeting.m4a", extraFiles: ["meeting.wav": 3_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    await f.shrink()
    #expect(!encoded.value)
    #expect(f.exists("meeting.m4a") && !f.exists("meeting.wav") && !f.exists("system-audio.f32"))
}

@Test("Every prefix of the deletion order leaves a folder that looks healthy (F795)")
@MainActor
func shrinkStopAnywhereNeverLooksDamaged() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    // Write a real manifest with matching frame counts, so the check is meaningful.
    let frames = 6_000_000 / 4
    let manifest = """
    {"systemAudio":{"file":"system-audio.f32","frameCount":\(frames)},
     "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(frames)}}
    """
    try Data(manifest.utf8).write(to: f.folder.appendingPathComponent("source-tracks.json"))
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)
        .write(to: f.folder.appendingPathComponent("meeting.wav"))
    try Data(count: 15_000).write(to: f.folder.appendingPathComponent("meeting.m4a"))
    let order = MeetingStoragePlan.removableFiles(in: MeetingStorageMeter.entries(in: f.folder), keeping: "meeting.m4a")
    // The meeting as the index names it once the copy is committed: Verify Library's descriptor is built from it the
    // way production builds it (F803) — `rawTracksWithoutManifest` derived from the folder, not assumed.
    let shrunk = MeetingRecord(id: f.id, title: "Weekly sync", duration: 1,
                               recordingPath: "Recordings/\(f.id.uuidString)/meeting.m4a", status: .completed, transcriptText: "Hi.")
    for entry in order {
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent(entry.name))
        let descriptor = try #require(f.model.integrityDescriptorForShrink(shrunk))
        let findings = MeetingIntegrityChecker.check(descriptor)
        #expect(!findings.contains { $0.isProblem }, "after removing \(entry.name): \(findings)")
        #expect(SourceRebuild.offer(in: f.folder, currentDuration: 1) == nil, "after removing \(entry.name)")
    }
}

@Test("A batch shrinks every eligible meeting and names the one that failed (F795)")
@MainActor
func shrinkBatchContinuesPastAFailure() async throws {
    // Review Focus 2.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let second = UUID()
    let secondFolder = f.root.appendingPathComponent("Recordings/\(second.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    try Fixture.writeCapture(in: secondFolder, recordingName: "meeting.wav", wavSeconds: 60)
    f.model.store.upsert(MeetingRecord(id: second, title: "Second", duration: 60,
                                       recordingPath: "Recordings/\(second.uuidString)/meeting.wav",
                                       status: .completed, transcriptText: "Hi."))
    let failing = f.folder.appendingPathComponent("meeting.wav").path
    f.model.encodeForShrink = { input, output, _ in
        if input.path == failing { throw AudioTranscoderError.transcodeFailed("boom") }
        try Data(count: 15_000).write(to: output)
    }
    await f.model.refreshStorage(ids: [f.id, second])
    f.model.requestShrink(ids: [f.id, second])
    await f.model.performShrink(confirmed: true)?.value
    #expect(FileManager.default.fileExists(atPath: secondFolder.appendingPathComponent("meeting.m4a").path))
    #expect(f.exists("meeting.wav"))
    #expect(f.model.alertMessage?.contains("Weekly sync") == true)
}

@Test("Backup and Shrink refuse each other (F795)")
@MainActor
func shrinkAndBackupAreExclusive() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.isBackingUpForTesting = true
    #expect(f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id))) == .backupRunning)
}

@Test("The confirmation says what changes, where the originals go, and what is lost (F795, F1040)")
@MainActor
func shrinkConfirmationStatesItsPromises() {
    let request = AppModel.ShrinkRequest(meetingIDs: [UUID()], titles: ["Weekly sync"], currentBytes: 1_728_000_000,
                                         predictedBytes: 14_800_000, skipped: [], includesUntranscribed: false,
                                         includesVideo: true)
    let text = AppModel.shrinkConfirmationMessage(request)
    #expect(AppModel.shrinkConfirmationTitle(request) == "Shrink “Weekly sync”?")
    #expect(text.contains("moved to the Trash") && text.contains("empty the Trash"), "F1040: \(text)")
    #expect(!text.contains("permanently"))
    #expect(text.contains("Rebuild Audio"))
    #expect(text.contains("picture is removed"))
    #expect(!text.contains("hasn't been transcribed"), "only said when it applies")
}

// MARK: - Final-review findings (F795)

/// An ordered record of seam calls, safe to append to from a `@Sendable` closure.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func hiddenTemps(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".shrink-") }
}

@Test("A recovered meeting whose tracks hold no more audio than it does can be shrunk (F795 review)")
@MainActor
func shrinkAcceptsARecoveredMeeting() async throws {
    // Finding 2: a recovered folder has no complete meeting.wav, so SourceRebuild always offers, and
    // treating every offer as damage made meeting-recovered.* unshrinkable. Tracks here are 31.25 s.
    let f = try Fixture(recordingName: "meeting-recovered.wav"); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    #expect(f.exists("meeting-recovered.m4a"), "\(f.model.alertMessage ?? "nil")")
    #expect(!f.exists("meeting-recovered.wav") && !f.exists("system-audio.f32"))
    #expect(f.persistedPath()?.hasSuffix("/meeting-recovered.m4a") == true)
}

@Test("A recovered meeting whose tracks hold more audio than it does is refused, untouched (F795 review)")
@MainActor
func shrinkRefusesATruncatedRecovery() async throws {
    // 10 s of recovered audio against 31.25 s of tracks: Rebuild Audio would recover the rest, and
    // shrinking would delete the tracks it needs.
    let f = try Fixture(recordingName: "meeting-recovered.wav", duration: 10, wavSeconds: 10)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    await f.model.refreshStorage(ids: [f.id])
    #expect(f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id)))
            == .damaged(rebuildOffered: true))
    await f.shrink()
    #expect(!encoded.value && f.exists("meeting-recovered.wav") && f.exists("system-audio.f32"))
}

@Test("A recording Verify Library calls damaged is refused through the app, untouched (F795 review)")
@MainActor
func shrinkRefusesADamagedRecording() async throws {
    // Finding 6: only the planner pinned this. Cut the WAV's data short so its header over-declares.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let wav = f.folder.appendingPathComponent("meeting.wav")
    let data = try Data(contentsOf: wav)
    try data.prefix(data.count / 2).write(to: wav)
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    await f.model.refreshStorage(ids: [f.id])
    let reason = f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id)))
    guard case .damaged = reason else { Issue.record("expected .damaged, got \(String(describing: reason))"); return }
    await f.shrink()
    #expect(!encoded.value && f.exists("meeting.wav") && f.exists("system-audio.f32") && f.exists("source-tracks.json"))
}

@Test("An interrupted import shrink is finished without a second encode (F795 review)")
@MainActor
func shrinkFinishesAnInterruptedImportWithoutEncoding() async throws {
    // Finding 3: the index names recording.m4a and the original recording.mp4 survived.
    let f = try Fixture(recordingName: "recording.m4a", extraFiles: ["recording.mp4": 3_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    await f.shrink()
    #expect(!encoded.value)
    #expect(f.exists("recording.m4a") && !f.exists("recording.mp4"))
}

@Test("The new file and its folder are flushed to disk before any original is removed (F795 review)")
@MainActor
func shrinkFlushesBeforeRemoving() async throws {
    // Finding 4: the full decode reads the page cache; without a flush a power loss after the
    // unlinks can leave neither copy.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let log = CallLog()
    f.model.flushForShrink = { url in log.append("flush \(url.lastPathComponent)") }
    f.model.willRemoveForShrink = { name in log.append("remove \(name)") }
    await f.shrink()
    let entries = log.entries
    let firstRemove = try #require(entries.firstIndex { $0.hasPrefix("remove ") }, "\(entries)")
    let file = entries.firstIndex { $0.hasPrefix("flush .shrink-") && $0.hasSuffix(".m4a") }
    let folder = entries.firstIndex { $0 == "flush \(f.id.uuidString)" }
    #expect(file.map { $0 < firstRemove } == true, "\(entries)")
    #expect(folder.map { $0 < firstRemove } == true, "\(entries)")
}

@Test("A flush that fails defers the shrink: nothing is committed or removed (F795 review)")
@MainActor
func shrinkFailedFlushChangesNothing() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.flushForShrink = { _ in throw POSIXError(.EIO) }
    await f.shrink()
    #expect(f.exists("meeting.wav") && f.exists("system-audio.f32") && f.exists("source-tracks.json"))
    #expect(f.persistedPath()?.hasSuffix("/meeting.wav") == true)
    #expect(try hiddenTemps(in: f.folder).isEmpty)
}

@Test("A restore in progress refuses Shrink with that reason, and Shrink refuses a restore (F795 review)")
@MainActor
func shrinkAndRestoreAreExclusive() async throws {
    // Finding 5.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.store.beginLibraryRestore()
    #expect(f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id))) == .libraryRestoring)
    f.model.store.endLibraryRestore()
    f.model.shrinkRunningID = f.id
    await f.model.requestLibraryRestore(from: f.root.appendingPathComponent("no-such-backup"))
    #expect(f.model.alertMessage?.contains("being shrunk") == true, "\(f.model.alertMessage ?? "nil")")
    f.model.shrinkRunningID = nil
}

@Test("A record that changes while its audio encodes is not committed (F795 review)")
@MainActor
func shrinkRechecksTheRecordAfterEncoding() async throws {
    // Finding 5: every guard ran before the encode's await; something can change the record in it.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let (started, startedSink) = AsyncStream<Void>.makeStream()
    let proceed = DispatchSemaphore(value: 0)
    f.model.encodeForShrink = { _, output, _ in
        startedSink.yield(())
        proceed.wait()
        try Data(count: 15_000).write(to: output)
    }
    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])
    let task = f.model.performShrink(confirmed: true)
    for await _ in started { break }
    #expect(f.model.store.replaceRecordingPath(id: f.id, with: "Recordings/\(f.id.uuidString)/meeting-recovered.wav"))
    proceed.signal()
    await task?.value
    #expect(f.exists("meeting.wav") && f.exists("system-audio.f32"))
    #expect(!f.exists("meeting.m4a"))
    #expect(try hiddenTemps(in: f.folder).isEmpty)
    #expect(f.persistedPath()?.hasSuffix("/meeting-recovered.wav") == true)
}

@Test("A measured encode too large to be worth it changes nothing (F795 review)")
@MainActor
func shrinkMeasuredAlreadyCompactChangesNothing() async throws {
    // Finding 6: the measured E is the authority (design, step 5). 15 MB against ~17.8 MB freed.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.encodeForShrink = { _, output, _ in try Data(count: 15_000_000).write(to: output) }
    await f.shrink()
    #expect(f.exists("meeting.wav") && f.exists("system-audio.f32") && !f.exists("meeting.m4a"))
    #expect(try hiddenTemps(in: f.folder).isEmpty)
    #expect(f.model.alertMessage?.contains("Already compact") == true, "\(f.model.alertMessage ?? "nil")")
}

@Test("Too little free space refuses before the encoder runs (F795 review)")
@MainActor
func shrinkRefusesWithoutFreeSpace() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    f.model.availableBytesForShrink = { _ in 1_000 }
    await f.shrink()
    #expect(!encoded.value && f.exists("meeting.wav"))
    #expect(f.model.alertMessage?.contains("free") == true, "\(f.model.alertMessage ?? "nil")")
}

@Test("The library total counts only meetings still in the library (F795 review)")
@MainActor
func shrinkLibraryTotalForgetsDeletedMeetings() async throws {
    // Finding 7.
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let second = UUID()
    let secondFolder = f.root.appendingPathComponent("Recordings/\(second.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    try Fixture.writeCapture(in: secondFolder, recordingName: "meeting.wav", wavSeconds: 60)
    f.model.store.upsert(MeetingRecord(id: second, title: "Second", duration: 60,
                                       recordingPath: "Recordings/\(second.uuidString)/meeting.wav",
                                       status: .completed, transcriptText: "Hi."))
    await f.model.refreshStorage(ids: [f.id, second])
    let both = f.model.measuredLibraryBytes
    #expect(f.model.store.delete(ids: [second]) == [second])
    await f.model.refreshStorage(ids: f.model.store.meetings.map(\.id))
    #expect(f.model.measuredLibraryBytes == f.model.storageBytes(for: f.id))
    #expect(f.model.measuredLibraryBytes < both)
}

// MARK: - The originals go to the Trash (F1040)

// The user's decision of 2026-10-17: Shrink moves the originals to the Mac's Trash instead of deleting them, so a
// check that missed a sound can be undone; a Trash that refuses keeps them where they are, never deletes them.

@MainActor
private func trashName(_ f: Fixture, _ file: String) throws -> String {
    let meeting = try #require(f.model.store.meeting(id: f.id))
    return MeetingStoragePlan.trashName(forFile: file, meetingTitle: meeting.title, createdAt: meeting.createdAt,
                                        meetingID: f.id)
}

@Test("Shrink moves the original recording and its raw tracks to the Trash, named for the meeting (F1040)")
@MainActor
func shrinkMovesTheOriginalsToTheTrash() async throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let originals = ["source-tracks.json", "microphone-audio.f32", "system-audio.f32", "meeting.wav"]
    let named = try originals.map { try trashName(f, $0) }
    #expect(f.trash.received == named, "\(f.trash.received)")
    for (original, name) in zip(originals, named) {
        #expect(!f.exists(original) && !f.exists(name), "\(original) is still in the meeting's folder")
        #expect(f.trash.holds(name), "\(name) never reached the Trash")
    }
    #expect(named.last?.hasPrefix("Weekly sync — ") == true && named.last?.hasSuffix(" — original meeting.wav") == true)
    #expect(f.exists("meeting.m4a") && f.exists("notes.md") && f.exists("diarization.json"))
    let alert = try #require(f.model.alertMessage)
    #expect(alert.contains("Shrunk") && alert.contains("in the Trash") && alert.contains("empty it"), "\(alert)")
}

@Test("A Trash that refuses keeps every original where it was, the meeting plays its copy, and Shrink says it could not finish (F1040)")
@MainActor
func aRefusingTrashKeepsTheOriginals() async throws {
    let f = try Fixture(failingTrash: true); defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try Data(contentsOf: f.folder.appendingPathComponent("meeting.wav"))
    await f.shrink()
    for original in ["source-tracks.json", "microphone-audio.f32", "system-audio.f32", "meeting.wav"] {
        let name = try trashName(f, original)
        #expect(f.exists(original), "\(original) was removed when the Trash refused it")
        #expect(!f.exists(name), "\(original) was left under its Trash name")
    }
    let after = try Data(contentsOf: f.folder.appendingPathComponent("meeting.wav"))
    #expect(after == before)
    // The copy is committed, so the meeting still plays.
    #expect(f.persistedPath()?.hasSuffix("/meeting.m4a") == true && f.exists("meeting.m4a"))
    let alert = try #require(f.model.alertMessage)
    #expect(alert.contains("could not finish") && alert.contains("still in the meeting's folder"), "\(alert)")
    #expect(!alert.contains("in the Trash;"), "\(alert)")
}

@Test("A resumed shrink moves its leftovers to the Trash too (F1040)")
@MainActor
func aResumeMovesLeftoversToTheTrash() async throws {
    let f = try Fixture(recordingName: "meeting.m4a", extraFiles: ["meeting.wav": 3_000_000])
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let wav = try trashName(f, "meeting.wav"), track = try trashName(f, "system-audio.f32")
    #expect(!f.exists("meeting.wav") && f.trash.holds(wav))
    #expect(f.trash.holds(track))
    #expect(f.exists("meeting.m4a"))
}

@Test("A file the copy replaces in place goes to the Trash, and stays as it was when the Trash refuses (F1040)")
@MainActor
func aFileReplacedInPlaceGoesToTheTrash() async throws {
    let f = try Fixture(extraFiles: ["meeting.m4a": 7]); defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let size = try f.folder.appendingPathComponent("meeting.m4a").resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(size == 15_000)
    let replaced = try trashName(f, "meeting.m4a")
    #expect(f.trash.holds(replaced), "the file the copy replaced was deleted: \(f.trash.received)")
    let replacedSize = try f.trash.folder.appendingPathComponent(replaced).resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(replacedSize == 7)
    let temps = try FileManager.default.contentsOfDirectory(atPath: f.folder.path).filter { $0.hasPrefix(".shrink-") }
    #expect(temps.isEmpty, "\(temps)")

    let refused = try Fixture(extraFiles: ["meeting.m4a": 7], failingTrash: true)
    defer { try? FileManager.default.removeItem(at: refused.root) }
    await refused.shrink()
    #expect(refused.exists("meeting.wav"), "the recording was removed when the Trash refused")
    let alert = try #require(refused.model.alertMessage)
    #expect(alert.contains("could not finish"), "\(alert)")
    // Kept in the folder for the next Shrink, which measures it as a leftover and tries the Trash again.
    let kept = try FileManager.default.contentsOfDirectory(atPath: refused.folder.path)
        .filter { $0.hasPrefix(".shrink-") && $0.contains(".replaced") }
    #expect(kept.count == 1, "the replaced file was not kept: \(kept)")
    if let kept = kept.first {
        let keptSize = try refused.folder.appendingPathComponent(kept).resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(keptSize == 7)
    }
}

@Test("Shrink's removals go through the Trash: nothing on its delete path unlinks or deletes an original (F1040)")
func shrinkHasNoDeletionOnItsRemovalPath() throws {
    // Comments stripped first, or the paragraph explaining the rule would satisfy or break it (F285).
    let code = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel+Shrink.swift")
    #expect(!code.contains("removeIfUnchanged"), "the delete step unlinks again")
    #expect(!code.contains("unlink("), "an unlink is back on Shrink's path")
    // Every removeItem left is one of this run's own scratch files, never a file the user had — or, F1074, an
    // earlier run's mix or kept read, named by `MeetingStoragePlan.staleMixScratch` (pinned in its own test).
    let scratch: Set<String> = ["tempM4A", "tempWAV", "mixWAV", "lanesFile", "decodedWAV", "readerWAV", "scratch", "staleScratch"]
    #expect(code.contains("for entry in MeetingStoragePlan.staleMixScratch(in: disk.entries)"), "staleScratch is named by the rule")
    let removed = code.components(separatedBy: "removeItem(at: ").dropFirst()
        .map { String($0.prefix { $0.isLetter || $0.isNumber }) }
    #expect(!removed.isEmpty && removed.allSatisfy(scratch.contains), "removeItem on something else: \(removed)")
    // The in-place replace keeps what it replaced, for the Trash.
    #expect(code.contains(".withoutDeletingBackupItem"), "the in-place replace deletes the file it replaces")
}
