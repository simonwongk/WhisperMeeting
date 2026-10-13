import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F969 — F477 cleared the typed title on both paths of `stopRecording` that save a meeting, so the
// next recording could not inherit it. Two branches of the failed stop save nothing and returned
// without the clear: the rebuild that throws ("could not be finalized automatically") and the rebuild
// that finds no usable audio ("No usable audio could be rebuilt"). The title then stayed in
// `recordingTitle`, invisibly when the next Start comes from the menu bar, and the next meeting was
// saved under the previous one's name. The folder's sidecar already holds the title for the launch
// that rebuilds it, so the in-memory copy has no use once the stop has given up.

private struct CaptureWouldNotStop: Error {}
private struct RebuildFailed: Error {}

/// Whether the capture's stop throws; flipped between the failed stop and the recording after it.
private final class StopFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    var isFailing: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
}

@MainActor
private func makeModel() throws -> (AppModel, StopFailure, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F969-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    let failure = StopFailure()
    let recorder = AudioCaptureEngine(
        stoppingCapture: { if failure.isFailing { throw CaptureWouldNotStop() } },
        finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    return (model, failure, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
private func recordTwoSeconds(_ model: AppModel) async throws -> UUID {
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2,
                                       systemStart: 0, microphoneStart: 0)
    return id
}

/// The recording after the failed stop, stopped normally: its saved title is what the field held.
@MainActor
private func nextRecordingTitle(_ model: AppModel, _ failure: StopFailure) async throws -> String {
    failure.isFailing = false
    let next = try await recordTwoSeconds(model)
    let saved = try #require(await model.stopRecording(title: model.recordingTitle))
    #expect(saved == next)
    return try #require(model.store.meeting(id: next)?.title)
}

@MainActor
@Test("A failed Stop whose rebuild finds no usable audio clears the typed title, so the next recording starts untitled (F969)")
func aStopWithNothingToRebuildClearsTheTitle() async throws {
    let (model, failure, cleanup) = try makeModel()
    defer { cleanup() }
    model.recoverInterruptedRecording = { _ in nil }
    model.recordingTitle = "Board call"
    _ = try await recordTwoSeconds(model)

    let saved = await model.stopRecording(title: model.recordingTitle)

    #expect(saved == nil)
    #expect(model.alertMessage?.contains("No usable audio could be rebuilt") == true, "\(model.alertMessage ?? "no message")")
    #expect(model.recordingState == .idle)
    #expect(model.recordingTitle.isEmpty, "the next recording inherits the title: \(model.recordingTitle)")
    #expect(try await nextRecordingTitle(model, failure) != "Board call")
}

@MainActor
@Test("A failed Stop whose rebuild itself fails clears the typed title too (F969)")
func aStopWhoseRebuildFailsClearsTheTitle() async throws {
    let (model, failure, cleanup) = try makeModel()
    defer { cleanup() }
    model.recoverInterruptedRecording = { _ in throw RebuildFailed() }
    model.recordingTitle = "Board call"
    _ = try await recordTwoSeconds(model)

    let saved = await model.stopRecording(title: model.recordingTitle)

    #expect(saved == nil)
    #expect(model.alertMessage?.contains("could not be finalized automatically") == true, "\(model.alertMessage ?? "no message")")
    #expect(model.recordingState == .idle)
    #expect(model.recordingTitle.isEmpty, "the next recording inherits the title: \(model.recordingTitle)")
    #expect(try await nextRecordingTitle(model, failure) != "Board call")
}
