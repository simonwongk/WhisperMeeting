import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1049 — `stopRecording` built the meeting with `createdAt`'s default, `Date()` at Stop, so a recorded
// meeting was listed, dated in notes.md and named ("Meeting <time>") by when it ended. The recording's
// own clock and the session sidecar both say when it began. I chose the start: a meeting is listed by
// when it began, as a calendar does, and the sidecar already calls that the recording's time.

@MainActor
private func recordingModel(_ label: String) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1049-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
    return (model, root)
}

@MainActor
private func startedRecording(_ model: AppModel) async throws -> (UUID, Date) {
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    guard case let .recording(startedAt) = model.recordingState else {
        Issue.record("fixture: the recording did not start")
        throw CancellationError()
    }
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000, microphone: 48_000, systemStart: 100.0, microphoneStart: 100.0)
    return (id, startedAt)
}

@MainActor
@Test("A recorded meeting is dated by when it began, not when it was stopped (F1049)")
func aRecordedMeetingIsDatedByItsStart() async throws {
    let (model, root) = try recordingModel("stop")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, startedAt) = try await startedRecording(model)
    _ = await model.stopRecording(title: "")

    let stored = try #require(model.store.meeting(id: id), "fixture: Stop did not index the meeting")
    #expect(stored.createdAt == startedAt, "dated \(stored.createdAt), started \(startedAt)")
    // The name a meeting gets when none was typed says the same time.
    #expect(stored.title == "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))", "\(stored.title)")
}

@MainActor
@Test("A recording stopped by the Mac going to sleep is dated by when it began too, from its session record (F1049)")
func aSleepStoppedRecordingIsDatedByItsStart() async throws {
    let (model, root) = try recordingModel("sleep")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, startedAt) = try await startedRecording(model)
    // Longer than the tolerance below, so a meeting dated at Stop cannot pass for one dated at Start.
    try await Task.sleep(for: .milliseconds(1_500))
    // Leaves `.recording` before the stop runs, so only the session sidecar still knows the start.
    model.handleSystemWillSleep(now: startedAt.addingTimeInterval(600))
    try await pollUntil("the sleep-stopped meeting to be indexed") { model.store.meeting(id: id) != nil }

    let stored = try #require(model.store.meeting(id: id))
    // The sidecar keeps whole seconds (ISO 8601), so the start it gives is within one of the clock's.
    #expect(abs(stored.createdAt.timeIntervalSince(startedAt)) < 1, "dated \(stored.createdAt), started \(startedAt)")
}
