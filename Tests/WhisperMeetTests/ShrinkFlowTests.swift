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

    // 60 s, so the predicted output (246 KB) is well under a quarter of these files and the
    // worth-it rule passes; an hour's prediction (14.8 MB) would make them "already compact".
    // The recording is a real WAV and the tracks have a matching manifest: zero-filled stand-ins
    // read as damaged to Verify Library and Rebuild Audio, and Shrink rightly refuses those.
    init(recordingName: String = "meeting.wav", duration: TimeInterval = 60, wavSeconds: Double = 60,
         recordingPath: String? = nil, extraFiles: [String: Int] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkFlow-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeCapture(in: folder, recordingName: recordingName, wavSeconds: wavSeconds)
        for (name, size) in extraFiles { try Data(count: size).write(to: folder.appendingPathComponent(name)) }
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "ShrinkFlow.\(UUID().uuidString)")!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Weekly sync", duration: duration,
            recordingPath: recordingPath ?? "Recordings/\(id.uuidString)/\(recordingName)",
            status: .completed, transcriptText: "Hi."))
        // Seams: a fake encode writes a small file; lengths agree unless a test says otherwise.
        model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }
        model.decodedDurationForShrink = { _ in wavSeconds }
        model.declaredDurationForShrink = { _ in wavSeconds }
        model.availableBytesForShrink = { _ in .max }
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
    #expect(!f.exists("meeting.m4a"))
    // It was the save that refused, not an earlier guard: the outcome is the failure sentence.
    #expect(f.model.alertMessage?.contains("could not be shrunk, and nothing was removed") == true,
            "\(f.model.alertMessage ?? "nil")")
}

@Test("A length mismatch or a failed encode changes nothing and leaves no temp files (F795)")
@MainActor
func shrinkVerificationFailureChangesNothing() async throws {
    for mode in ["mismatch", "throws"] {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if mode == "mismatch" {
            f.model.decodedDurationForShrink = { _ in 1_800 }
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
    let odd = try Fixture(recordingPath: "Elsewhere/meeting.wav")
    defer { try? FileManager.default.removeItem(at: odd.root) }
    let encoded = CallFlag()
    odd.model.encodeForShrink = { _, _, _ in encoded.set() }
    await odd.shrink()
    #expect(!encoded.value && odd.exists("system-audio.f32"))
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
    for entry in order {
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent(entry.name))
        let m4a = f.folder.appendingPathComponent("meeting.m4a")
        let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
            recordingURL: m4a, sourceTracks: AppModel.sourceTracks(in: f.folder), indexDurationSeconds: 1,
            rawTracksWithoutManifest: false))
        #expect(!findings.contains { $0.isProblem }, "after removing \(entry.name)")
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

@Test("The confirmation says what changes, that it is permanent, and what is lost (F795)")
@MainActor
func shrinkConfirmationStatesItsPromises() {
    let request = AppModel.ShrinkRequest(meetingIDs: [UUID()], titles: ["Weekly sync"], currentBytes: 1_728_000_000,
                                         predictedBytes: 14_800_000, skipped: [], includesUntranscribed: false,
                                         includesVideo: true)
    let text = AppModel.shrinkConfirmationMessage(request)
    #expect(AppModel.shrinkConfirmationTitle(request) == "Shrink “Weekly sync”?")
    #expect(text.contains("deleted permanently"))
    #expect(text.contains("Rebuild Audio"))
    #expect(text.contains("picture is removed"))
    #expect(!text.contains("hasn't been transcribed"), "only said when it applies")
}
