import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F641 — F477 moved the typed title's reset into `AppModel.stopRecording(title:)`, on both paths that
// save a meeting. The record screen's Stop button still cleared it again itself afterwards: "" onto
// "". Harmless, but it meant a future save path in `stopRecording` that forgot the clear would stay
// hidden behind the button — the one stop route a person checking by hand is most likely to use —
// while the menu bar, ⌘R, sleep and capture-loss routes all leaked the title into the next meeting.
//
// So the view's copy goes, and the model's clear is pinned for the call the button makes: an
// explicit typed title, on the normal save and on the recovered-after-a-finishing-error save.

private struct CaptureWouldNotStop: Error {}

@MainActor
private func makeModel(stopFails: Bool) throws -> (AppModel, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F641-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    let recorder = AudioCaptureEngine(
        stoppingCapture: { if stopFails { throw CaptureWouldNotStop() } },
        finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    return (model, {
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

@MainActor
@Test("The record screen's Stop — an explicit typed title — leaves the title cleared by the model itself (F641)")
func inWindowStopIsClearedByTheModel() async throws {
    let (model, cleanup) = try makeModel(stopFails: false)
    defer { cleanup() }
    model.recordingTitle = "Board call"
    let id = try await recordTwoSeconds(model)

    // Exactly the call `handlePrimaryAction` makes, and nothing after it.
    let saved = try #require(await model.stopRecording(title: model.recordingTitle))

    #expect(saved == id)
    #expect(model.store.meeting(id: id)?.title == "Board call")
    #expect(model.recordingTitle.isEmpty, "only the view's own line was clearing it on this path")
}

@MainActor
@Test("The same holds when the stop saves a recovered meeting after a finishing error (F641)")
func inWindowStopOnTheRecoveryPathIsClearedByTheModel() async throws {
    let (model, cleanup) = try makeModel(stopFails: true)
    defer { cleanup() }
    model.recordingTitle = "Board call"
    let id = try await recordTwoSeconds(model)

    let saved = try #require(await model.stopRecording(title: model.recordingTitle),
                             "the real rebuild recovers the tracks the capture wrote")

    #expect(saved == id)
    #expect(model.store.meeting(id: id)?.recoverySource != nil, "sanity: this was the recovery path")
    #expect(model.store.meeting(id: id)?.title == "Board call")
    #expect(model.recordingTitle.isEmpty)
}

@Test("The record screen's Stop does not clear the title itself after stopRecording (F641)")
func theStopButtonLeavesTheClearToTheModel() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let action = try #require(content.range(of: "private func handlePrimaryAction() {"))
    let stop = try #require(content[action.upperBound...].range(of: "model.stopRecording(title: model.recordingTitle)"))
    // The function ends at the next `private func`.
    let end = content[stop.upperBound...].range(of: "private func ")?.lowerBound ?? content.endIndex
    #expect(!content[stop.upperBound..<end].contains("recordingTitle = \"\""),
            "a second clear in the view hides a stopRecording path that forgets its own")
}
