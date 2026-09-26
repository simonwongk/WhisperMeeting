import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F477 — two faults in stopping/cancelling from outside the in-window controls.
//
// Part 1: Recording ▸ Cancel Recording… (and its menu-bar/⌘-adjacent routes) called
// `model.requestCancelConfirmation()`, which only ever set `isConfirmingCancellation`.  The only
// view presenting a dialog for it was `RecordMeetingView`, built only while the sidebar selection
// is "New Meeting" — so from any other pane, or with the window closed, nothing appeared, and
// because nothing cleared the flag on any OTHER exit from `.recording`, it could later fire the
// dialog against a completely different recording.
//
// Part 2: `AppModel.recordingTitle` (F298) is the fallback `stopRecording(title:)` reads when the
// caller passes "" — every windowless stop route (menu bar, ⌘R, sleep, capture-loss finalize). Only
// `ContentView` ever cleared it afterwards, and only following its own in-window Stop button or an
// import — so a title typed for one meeting silently became the fallback for the next one whenever
// the actual stop went through any other route.

private struct StreamDied: Error {}

@MainActor
private func makeModel() throws -> (AppModel, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F477-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F477.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") }, qwenInstalled: { true }
    )
    return (model, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
private func attachTracks(_ model: AppModel, seconds: Int64 = 2) throws -> UUID {
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * seconds, microphone: 48_000 * seconds,
                                       systemStart: 0, microphoneStart: 0)
    return id
}

// MARK: - Part 1: the confirmation must not depend on which pane is showing, and must not outlive
// the recording it was raised for.

@Test("The cancel-confirmation dialog is on ContentView's own root, not on RecordMeetingView (F477)")
func cancelConfirmationDialogIsOnContentViewNotRecordMeetingView() throws {
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8)
    )
    let contentViewStart = try #require(source.range(of: "struct ContentView: View {"))
    let recordMeetingViewStart = try #require(source.range(of: "private struct RecordMeetingView: View {"))
    #expect(contentViewStart.lowerBound < recordMeetingViewStart.lowerBound, "sanity: declaration order")

    // The next `private struct` after RecordMeetingView bounds its extent; if there isn't one this
    // falls back to the end of the file, which still correctly excludes anything before it.
    let afterRecordMeetingView = source[recordMeetingViewStart.upperBound...]
    let recordMeetingViewEnd = afterRecordMeetingView.range(of: "\nprivate struct ")?.lowerBound
        ?? source.endIndex

    let contentViewRegion = source[contentViewStart.lowerBound..<recordMeetingViewStart.lowerBound]
    let recordMeetingViewRegion = source[recordMeetingViewStart.lowerBound..<recordMeetingViewEnd]

    #expect(contentViewRegion.contains("isPresented: $model.isConfirmingCancellation"),
            "the dialog must be reachable from ContentView's own root, present for as long as the window is open")
    #expect(!recordMeetingViewRegion.contains("isPresented: $model.isConfirmingCancellation"),
            "RecordMeetingView is built only for the \"New Meeting\" sidebar selection, so a dialog hosted there is unreachable from anywhere else")
}

@Test("A stop clears a pending cancel-confirmation, so it cannot later fire against a different recording (F477)")
@MainActor
func stopClearsAPendingCancelConfirmation() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    await model.startRecording()
    _ = try attachTracks(model)

    // Raised from some OTHER pane (or the menu), never acted on.
    model.requestCancelConfirmation()
    #expect(model.isConfirmingCancellation)

    _ = await model.stopRecording(title: "First meeting")
    #expect(!model.isConfirmingCancellation, "a stale confirmation must not survive the stop it was never shown for")

    // The next recording must not inherit a stale, already-answered dialog.
    await model.startRecording()
    #expect(!model.isConfirmingCancellation)
}

@Test("Cancelling clears the confirmation flag too, including the menu bar's own two-step route that bypasses the dialog (F477)")
@MainActor
func cancelClearsTheConfirmationFlag() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    await model.startRecording()
    _ = try attachTracks(model)

    // The menu bar's "Cancel Recording… ▸ Discard Recording" submenu calls `cancelRecording()`
    // directly (AppEntry.swift), bypassing `requestCancelConfirmation()`/the dialog entirely — so
    // this pins that `cancelRecording()` resets the flag on its own, not merely as a side effect of
    // the dialog's two-way binding.
    model.requestCancelConfirmation()
    #expect(model.isConfirmingCancellation)
    await model.cancelRecording()
    #expect(!model.isConfirmingCancellation)
}

// MARK: - Part 2: every stop path must clear `recordingTitle`, not just the in-window button.

@Test("A menu-bar-style stop (empty title, the windowless path) still clears recordingTitle after saving (F477)")
@MainActor
func windowlessStopClearsRecordingTitle() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try attachTracks(model)

    // "" is exactly what the menu-bar Stop and the ⌘R toggle pass (AppEntry.swift), simulating a
    // stop that never went through `RecordMeetingView`'s own text field or Stop button.
    let saved = try #require(await model.stopRecording(title: ""))
    #expect(saved == id)
    #expect(model.store.meeting(id: id)?.title == "Board call", "the fallback must still use the typed title")
    #expect(model.recordingTitle.isEmpty,
            "left set, this reappears as the fallback for the NEXT recording — the bug's actual impact")
}

@Test("A title typed for one meeting is not silently reused for the next after a windowless stop (F477)")
@MainActor
func titleDoesNotLeakIntoTheNextRecording() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    model.recordingTitle = "Board call"
    await model.startRecording()
    let first = try attachTracks(model)
    _ = await model.stopRecording(title: "")   // windowless: menu bar / ⌘R / sleep / capture-loss

    await model.startRecording()
    let second = try attachTracks(model)
    _ = await model.stopRecording(title: "")

    #expect(model.store.meeting(id: first)?.title == "Board call")
    #expect(model.store.meeting(id: second)?.title != "Board call",
            "the second meeting must fall back to its own generated name, not the first meeting's title")
}
