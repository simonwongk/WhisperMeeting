import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F753 — a missing `source-tracks.json` for an indexed capture is written back from the alignment the
// session sidecar kept at Stop, never from invented zeros.
//
// The write in `stop()` is made to fail with ManifestWriteFailureTests' trick (a directory at the
// manifest's path), the meeting is indexed by the real Stop, the obstruction is removed, and the pass
// runs. The microphone starts 0.2 s after the system audio, so a manifest of zeros is told apart.

@MainActor
private func makeModel(root: URL) throws -> AppModel {
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder,
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    model.crashReportsSince = { _ in [] }
    model.runWhisperInstallRecovery = { _ in 0 }
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }
    return model
}

/// A Stop whose own manifest write fails, then the obstruction removed: an indexed capture with a
/// complete `meeting.wav`, both raw tracks and no manifest.
@MainActor
private func stopWithAFailedManifestWrite(_ label: String) async throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F753-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = try makeModel(root: root)
    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let folder = model.store.recordingDirectoryURL(for: id)
    try model.recorder.beginTestTrackSession(in: folder)
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2 - 9_600,
                                       systemStart: 100.0, microphoneStart: 100.2)
    let obstruction = folder.appendingPathComponent("source-tracks.json")
    try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
    _ = await model.stopRecording(title: model.recordingTitle)
    try #require(model.store.meeting(id: id) != nil, "fixture: Stop did not index the meeting")
    try FileManager.default.removeItem(at: obstruction)
    try #require(!FileManager.default.fileExists(atPath: obstruction.path))
    return (root, model, id, folder)
}

private func manifestObject(in folder: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: folder.appendingPathComponent("source-tracks.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("A capture whose Stop failed to write source-tracks.json gets it back with the capture-time offsets (F753)")
@MainActor
func aFailedManifestWriteIsRetriedWithTheCapturedOffsets() async throws {
    let (root, model, id, folder) = try await stopWithAFailedManifestWrite("retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try #require(model.store.meeting(id: id))
    let before = try #require(model.verifyLibraryIntegrity(includingUncheckedSourceTracks: true).first { $0.meeting.id == id })
    try #require(before.findings.contains(.sourceTrackManifestMissing), "fixture: \(before.findings)")

    let written = await model.retryMissingSourceTrackManifests()

    #expect(written == 1)
    let manifest = try manifestObject(in: folder)
    #expect(manifest["recoveryAlignment"] as? String == SourceTrackManifest.capturedAlignment)
    let system = try #require(manifest["systemAudio"] as? [String: Any])
    let microphone = try #require(manifest["microphoneAudio"] as? [String: Any])
    #expect(abs((system["startOffsetSeconds"] as? Double ?? -1) - 0) < 0.000_1)
    #expect(abs((microphone["startOffsetSeconds"] as? Double ?? -1) - 0.2) < 0.001, "\(microphone)")
    #expect(system["frameCount"] as? Int == 96_000)
    #expect(microphone["frameCount"] as? Int == 86_400)
    #expect(model.verifyLibraryIntegrity(includingUncheckedSourceTracks: true).first { $0.meeting.id == meeting.id } == nil,
            "Verify Library still reports the tracks as unchecked")

    // A meeting that already has a manifest stays byte for byte as it was.
    let bytes = try Data(contentsOf: folder.appendingPathComponent("source-tracks.json"))
    #expect(await model.retryMissingSourceTrackManifests() == 0)
    #expect(try Data(contentsOf: folder.appendingPathComponent("source-tracks.json")) == bytes)
}

@Test("A session from a build without the offsets gets no manifest, never zeros (F753)")
@MainActor
func aSessionWithoutOffsetsGetsNoManifest() async throws {
    let (root, model, _, folder) = try await stopWithAFailedManifestWrite("old-session")
    defer { try? FileManager.default.removeItem(at: root) }
    // The session as a build before F753 left it: the same file without the new key.
    let sessionURL = folder.appendingPathComponent(RecordingSessionSidecar.filename)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any])
    try #require(object["capturedAlignment"] != nil, "fixture: Stop did not keep the alignment")
    object["capturedAlignment"] = nil
    try JSONSerialization.data(withJSONObject: object).write(to: sessionURL)

    #expect(await model.retryMissingSourceTrackManifests() == 0)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("source-tracks.json").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("source-tracks.recovered.json").path))
}

@Test("The next launch writes the missing manifest, through startup recovery (F753)")
@MainActor
func theLaunchRetriesTheMissingManifest() async throws {
    let (root, _, _, folder) = try await stopWithAFailedManifestWrite("launch")
    defer { try? FileManager.default.removeItem(at: root) }

    let relaunched = try makeModel(root: root)
    await relaunched.performStartupRecovery()

    let manifest = try manifestObject(in: folder)
    let microphone = try #require(manifest["microphoneAudio"] as? [String: Any])
    #expect(abs((microphone["startOffsetSeconds"] as? Double ?? -1) - 0.2) < 0.001, "\(microphone)")
}
