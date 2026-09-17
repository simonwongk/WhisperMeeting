import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F258 — the app wiring for the session sidecar.
//
// `RecordingSessionSidecarTests` covers the on-disk format; this covers that a live recording
// actually writes it, which is what AGENTS.md's reachability rule is for. Asserted THROUGH
// `AppModel.startRecording` / `addLiveMarker` over a real temp `MeetingStore`, with the capture
// engine's own injection seam standing in for the microphone — never by calling the core directly.

@MainActor
private func makeRecordingModel() throws -> (AppModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingSessionPersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F258.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    // The engine's injected `startingCapture` returns before any permission prompt or SCStream, so a
    // test can reach `.recording` without a microphone or Screen Recording grant.
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
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    return (model, root, defaults, suite)
}

@MainActor
@Test("Starting a recording writes a session sidecar beside the audio (F258)")
func startingARecordingWritesTheSidecar() async throws {
    let (model, root, defaults, suite) = try makeRecordingModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID, "the recording did not start")

    // The sidecar must exist from the moment capture begins — an interruption one second in should
    // still find the session, not just a folder of raw audio.
    let directory = model.store.recordingDirectoryURL(for: id)
    let session = try #require(RecordingSessionSidecar.read(in: directory),
                               "no session.json was written when recording started")
    #expect(session.id == id)
    #expect(session.markers.isEmpty)
}

@MainActor
@Test("Each marker is persisted as it is dropped, not at stop (F258)")
func markersArePersistedAsTheyAreDropped() async throws {
    let (model, root, defaults, suite) = try makeRecordingModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)

    model.addLiveMarker(label: "pricing")
    model.addLiveMarker(label: "headcount")

    // This is the whole ticket: the offsets are on disk BEFORE stop, so a crash keeps them. A
    // marker's offset cannot be reconstructed afterwards — a title can be retyped, a moment in 90
    // minutes of audio cannot be found again.
    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.markers.count == 2)
    #expect(session.markers.map(\.label) == ["pricing", "headcount"])
    #expect(session.markers == model.pendingMarkers,
            "the sidecar and the in-memory list must not be able to disagree")
}

@MainActor
@Test("A failed stop leaves the sidecar on disk for the next launch to read (F258)")
func failedStopLeavesTheSidecar() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingSessionPersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F258.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    struct StopFailure: Error {}
    let recorder = AudioCaptureEngine(
        stoppingCapture: { throw StopFailure() },   // finalization fails, as F47's path expects
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: recorder,
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.addLiveMarker(label: "pricing")

    // Make the rebuild succeed so the catch path reaches its upsert, exactly as F47 does.
    model.recoverInterruptedRecording = { directory in
        RecoveredRecording(
            recordingURL: directory.appendingPathComponent("meeting-recovered.wav"),
            duration: 42,
            source: .rebuiltSourceTracks
        )
    }

    _ = await model.stopRecording(title: "")

    // NOT asserting the recovered meeting's markers: the stop-failure path already carries them
    // through in-memory `pendingMarkers` (`AppModel.swift:1825`), so that would pass with or without
    // this ticket — a test that cannot fail for the change it claims to cover.
    //
    // What the sidecar is actually for is the case this process cannot demonstrate: a *different*
    // launch, after a crash or ⌘Q, where `pendingMarkers` is gone. So assert the one thing that
    // makes that possible and is in reach here — the file survives a failed stop rather than being
    // cleaned up with the rest of the attempt.
    let session = try #require(RecordingSessionSidecar.read(in: directory),
                               "the sidecar must outlive a failed stop, or recovery has nothing to read")
    #expect(session.markers.count == 1)
    #expect(session.markers.first?.label == "pricing")
}

@MainActor
@Test("Cancelling a recording takes the sidecar with the folder (F258)")
func cancellingRemovesTheSidecar() async throws {
    let (model, root, defaults, suite) = try makeRecordingModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.addLiveMarker(label: "pricing")
    #expect(RecordingSessionSidecar.read(in: directory) != nil)

    await model.cancelRecording()

    // Cancel is the one destructive path and it must stay destructive: a discarded recording must
    // not leave metadata behind for startup recovery to resurrect as an empty meeting.
    #expect(RecordingSessionSidecar.read(in: directory) == nil)
}
