import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F253 — the app wiring for the sleep handler.
//
// `RecordingSleepPolicyTests` pins the transition table; this pins that `AppModel` asks it and acts
// on the answer. Asserted through `handleSystemWillSleep` over a real temp `MeetingStore`, with the
// capture engine's injection seam standing in for the microphone.
//
// The guarantee under test is the *note*, not the finalize. macOS allows a few seconds on
// `willSleep` and mixing a 63-minute capture means reading ~1.4 GB, so the stop is best-effort by
// construction — asserting it completed would be asserting something the platform does not promise.

@MainActor
private func makeSleepModel() throws -> (AppModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SleepInterruptionWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F253.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
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
@Test("Sleeping mid-recording records the interruption in the sidecar (F253)")
func sleepDuringRecordingIsNoted() async throws {
    let (model, root, defaults, suite) = try makeSleepModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.addLiveMarker(label: "pricing")

    let at = Date(timeIntervalSince1970: 1_757_000_500)
    model.handleSystemWillSleep(now: at)

    // The fast, guaranteed half: recovery can now say the Mac slept rather than showing a generic
    // interruption notice — and the markers dropped before the sleep are still there.
    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.interruptedBySleepAt == at)
    #expect(session.markers.count == 1)
    #expect(session.markers.first?.label == "pricing")
}

@MainActor
@Test("Sleeping while idle touches nothing (F253)")
func sleepWhileIdleDoesNothing() throws {
    let (model, root, defaults, suite) = try makeSleepModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    // No recording, so no folder and nothing to note. It must not invent either.
    model.handleSystemWillSleep()
    #expect(model.activeMeetingID == nil)
    #expect(model.store.meetings.isEmpty)
    let recordings = root.appendingPathComponent("Recordings")
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
    #expect(contents.isEmpty, "a sleep while idle created a recording folder")
}

@MainActor
@Test("A second sleep notification does not re-note or double-stop (F253)")
func repeatedSleepIsHarmless() async throws {
    let (model, root, defaults, suite) = try makeSleepModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)

    let first = Date(timeIntervalSince1970: 1_757_000_500)
    model.handleSystemWillSleep(now: first)
    // macOS can post `willSleep` more than once around a failed sleep attempt. The state machine is
    // the guard: the first call moves the recording out of `.recording`, and the policy makes every
    // later phase a no-op — so the recorded moment stays the FIRST one.
    model.handleSystemWillSleep(now: Date(timeIntervalSince1970: 1_757_009_999))

    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.interruptedBySleepAt == first,
            "a repeated willSleep overwrote the moment the Mac actually slept")
}
