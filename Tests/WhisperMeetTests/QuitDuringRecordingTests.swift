import AppKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F529 — there was no `applicationShouldTerminate`, so ⌘Q, the menu bar's "Quit WhisperMeet" and
// Dock ▸ Quit all ended a live recording at once: no question, no `stopRecording`, and the meeting
// left for the next launch to rebuild as an interrupted folder. Cancel, which also cuts a meeting
// short, is confirmed twice.
//
// Driven through `AppLifecycle.shouldTerminate(reply:)` — the whole decision the delegate hands to
// AppKit — over a real `AppModel` whose engine writes real tracks, so "Stop & Quit" is checked by
// what lands in the library, not by a flag. The AppKit half (the delegate method and the `NSAlert`)
// cannot run in a test process and is pinned by source at the bottom.

private struct CaptureWouldNotStop: Error {}

/// Holds something open until the test lets it go, so "a stop is still saving" is a state the test
/// controls rather than a race it hopes to win (F672, F673).
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private func makeModel(stopFails: Bool = false, stopGate: Gate? = nil, engineInstalled: Bool = false) throws -> (AppModel, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F529-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    let recorder = AudioCaptureEngine(
        stoppingCapture: {
            if let stopGate { await stopGate.wait() }
            if stopFails { throw CaptureWouldNotStop() }
        },
        finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    // By default no engine is installed, so a saved meeting does not start a transcription a test
    // would then have to wait out. F673's test installs a stub one, because that is its subject.
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { engineInstalled ? URL(fileURLWithPath: "/tmp/whisper-stub") : nil },
        qwenInstalled: { engineInstalled }
    )
    return (model, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
private func startRecordingWithTracks(_ model: AppModel) async throws -> UUID {
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try #require(model.recordingState.isLive, "the recording never went live")
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2,
                                       systemStart: 0, microphoneStart: 0)
    return id
}

/// The lifecycle wired by the app's own `wireQuitDuringRecording`, which `WhisperMeetApp.init()`
/// calls, with the question answered by `answer`. Not a copy of the wiring (F810): a copy kept these
/// tests green with the app's `isRecordingFinishing` set back to the predicate F672 replaced.
@MainActor
private func makeLifecycle(for model: AppModel, answer: @escaping () -> AppLifecycle.QuitDuringRecordingChoice) -> (AppLifecycle, asked: Locked<Int>) {
    let asked = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.wireQuitDuringRecording(to: model) {
        asked.withLock { $0 += 1 }
        return answer()
    }
    return (lifecycle, asked)
}

/// Waits for the one reply a `.terminateLater` owes AppKit — the subject of the assertion, polled
/// against the wall clock with a cap far past any real stop, and required rather than assumed.
@MainActor
private func waitForReply(_ replies: Locked<[Bool]>) async throws {
    let deadline = Date().addingTimeInterval(30)
    while replies.withLock({ $0.isEmpty }), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(!replies.withLock { $0.isEmpty }, "the quit was never answered — AppKit would wait forever")
}

@MainActor
@Test("Quitting with nothing recording quits at once and asks nothing (F529)")
func quitWhileIdleQuitsNow() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    let (lifecycle, asked) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    #expect(decision == .terminateNow)
    #expect(asked.withLock { $0 } == 0, "an idle quit must not ask anything")
    #expect(replies.withLock { $0 }.isEmpty, "terminateNow owes AppKit no reply")
}

@MainActor
@Test("Keep Recording cancels the quit and leaves the recording running (F529)")
func keepRecordingCancelsTheQuit() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, asked) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    #expect(asked.withLock { $0 } == 1, "a quit during a live recording must ask first")
    #expect(decision == .terminateCancel)
    #expect(replies.withLock { $0 }.isEmpty, "terminateCancel owes AppKit no reply")
    #expect(model.recordingState.isLive, "Keep Recording must keep recording")
    #expect(model.activeMeetingID == id)
    #expect(model.store.meeting(id: id) == nil, "nothing was stopped, so nothing is indexed yet")
    await model.cancelRecording()
}

@MainActor
@Test("Stop & Quit saves the meeting properly, then quits with exactly one reply (F529)")
func stopAndQuitFinalizesTheMeetingThenQuits() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    model.recordingTitle = "Quarterly review"
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, asked) = makeLifecycle(for: model) { .stopAndQuit }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    #expect(asked.withLock { $0 } == 1)
    try #require(decision == .terminateLater, "the stop takes time, so AppKit must be told to wait for it")
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true], "exactly one answer, and it is to quit")

    // Saved by the ordinary stop, not left for the next launch to rebuild as an interrupted folder.
    let meeting = try #require(model.store.meeting(id: id), "Stop & Quit must index the meeting before quitting")
    #expect(meeting.title == "Quarterly review", "the title typed during the recording is kept")
    #expect(meeting.status == .recorded)
    #expect(meeting.errorMessage == nil)
    #expect(meeting.recoverySource == nil, "a properly finished meeting is not a recovered one")
    let wav = model.store.recordingDirectoryURL(for: id).appendingPathComponent("meeting.wav")
    #expect(FileManager.default.fileExists(atPath: wav.path), "the mixed recording was written")
    #expect(model.recordingState == .idle)
    #expect(model.activeMeetingID == nil)
}

@MainActor
@Test("A second quit while Stop & Quit is still saving is refused, and the first still gets its one reply (F529)")
func aSecondQuitDuringTheStopIsRefused() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    _ = try await startRecordingWithTracks(model)
    let (lifecycle, asked) = makeLifecycle(for: model) { .stopAndQuit }
    let replies = Locked<[Bool]>([])

    let first = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }
    // ⌘Q pressed again before the stop has finished: the pending decision answers for both.
    let second = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(first == .terminateLater, "only a terminateLater is owed a reply")
    #expect(second == .terminateCancel, "a re-entrant quit must not start a second stop or owe a second reply")
    #expect(asked.withLock { $0 } == 1, "the question is asked once")
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true])
}

@MainActor
@Test("A second quit while the question is still on screen is refused rather than stacking a second question (F529)")
func aSecondQuitDuringTheQuestionIsRefused() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    _ = try await startRecordingWithTracks(model)
    let lifecycleBox = Locked<AppLifecycle?>(nil)
    let nested = Locked<[NSApplication.TerminateReply]>([])
    let depth = Locked(0)
    let (lifecycle, asked) = makeLifecycle(for: model) {
        // The alert runs modally inside `shouldTerminate`; ⌘Q or Dock ▸ Quit can arrive during it.
        // Nested once only, so a regression shows as a second question rather than as a recursion.
        depth.withLock { $0 += 1 }
        if depth.withLock({ $0 }) == 1, let inner = lifecycleBox.withLock({ $0 }) {
            nested.withLock { $0.append(inner.shouldTerminate { _ in Issue.record("a refused quit was replied to") }) }
        }
        return .keepRecording
    }
    lifecycleBox.withLock { $0 = lifecycle }

    let decision = lifecycle.shouldTerminate { _ in Issue.record("terminateCancel owes no reply") }

    #expect(decision == .terminateCancel)
    #expect(nested.withLock { $0 } == [.terminateCancel], "the nested quit must be refused, not asked again")
    #expect(asked.withLock { $0 } == 1, "one question on screen at a time")
    #expect(model.recordingState.isLive)
    await model.cancelRecording()
}

@MainActor
@Test("A Stop & Quit whose stop cannot save anything cancels the quit so the failure stays on screen (F529)")
func aFailedStopCancelsTheQuit() async throws {
    let (model, cleanup) = try makeModel(stopFails: true)
    defer { cleanup() }
    // Nothing can be rebuilt either, so `stopRecording` reports the failure and returns nil.
    model.recoverInterruptedRecording = { _ in nil }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .stopAndQuit }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(decision == .terminateLater)
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [false], "quitting now would take the failure message with it")
    let message = try #require(model.alertMessage)
    #expect(message.contains(model.store.recordingDirectoryURL(for: id).path),
            "the user is told where the preserved folder is")
    #expect(FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id).path),
            "the folder is kept for a later launch to rebuild")
}

@MainActor
@Test("A recording that ended by itself while the question was up still lets Stop & Quit quit (F529)")
func aRecordingThatEndedDuringTheQuestionStillQuits() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    _ = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) {
        // The capture died and was finalized while the alert was on screen (F275's finalize path);
        // modelled by the state it leaves behind.
        model.setRecordingStateForTesting(.idle)
        model.setActiveMeetingIDForTesting(nil)
        return .stopAndQuit
    }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(decision == .terminateLater)
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true], "nothing is left to save, so the quit goes ahead")
}

@MainActor
@Test("A Stop & Quit that finds a sleep's stop already saving the recording waits for it, then quits (F529, F672)")
func aStopBegunUnderTheQuestionIsWaitedFor() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    model.recordingTitle = "Standup"
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) {
        // The Mac began to sleep while the alert was on screen: its stop takes the recording to
        // `.stopping` synchronously and saves it asynchronously — the capture-loss finalize's shape too.
        model.handleSystemWillSleep()
        return .stopAndQuit
    }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(decision == .terminateLater)
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true], "once that stop has saved the meeting, the quit goes ahead")
    #expect(model.store.meeting(id: id)?.title == "Standup", "saved by the stop that was already under way")
    #expect(model.recordingState == .idle)
}

// MARK: - F673: Stop & Quit does not start a transcription it is about to quit under

@MainActor
@Test("Stop & Quit with an engine installed saves the meeting ready to transcribe, without starting a job it would quit under (F673)")
func stopAndQuitDoesNotStartATranscription() async throws {
    let (model, cleanup) = try makeModel(engineInstalled: true)
    defer { cleanup() }
    // A stub engine that never finishes on its own: a job that starts is visibly running at the reply.
    let engine = Gate()
    defer { Task { await engine.open() } }
    model.runTranscriptionEngineOverride = { _, _ in
        await engine.wait()
        return TranscriptionResult(id: "stub", text: "Done.", languageCode: "en", audioDuration: 2, confidence: nil,
                                   segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "Done.")])
    }
    try #require(model.isSelectedEngineInstalled, "sanity: the stub engine counts as installed")
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .stopAndQuit }
    let atReply = Locked<(quit: Bool, active: Bool, queued: Bool, status: MeetingStatus?)?>(nil)

    let decision = lifecycle.shouldTerminate { quit in
        atReply.withLock { $0 = (quit, model.hasActiveTranscription, model.isQueuedForTranscription(id),
                                 model.store.meeting(id: id)?.status) }
    }
    try #require(decision == .terminateLater)
    let deadline = Date().addingTimeInterval(30)
    while atReply.withLock({ $0 == nil }), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    let seen = try #require(atReply.withLock { $0 }, "the quit was never answered")

    #expect(seen.quit)
    #expect(!seen.active, "a transcription started here is killed by the quit and reopens as interrupted")
    #expect(!seen.queued)
    #expect(seen.status == .recorded, "saved, and ready to transcribe at the next launch")
    #expect(!model.hasActiveTranscription && model.store.meeting(id: id)?.status == .recorded,
            "and nothing starts one after the reply either")
}

// MARK: - F672: a quit while a stop is still saving

/// Polls the recording's phase — the precondition's own subject — against the wall clock.
@MainActor
private func waitUntilStopping(_ model: AppModel) async throws {
    let deadline = Date().addingTimeInterval(30)
    while model.recordingState != .stopping, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(model.recordingState == .stopping, "the stop never reached .stopping")
}

@MainActor
@Test("A quit while Stop is still saving waits for that stop, asks nothing, and then quits (F672)")
func aQuitWhileAStopIsSavingWaitsForIt() async throws {
    let gate = Gate()
    let (model, cleanup) = try makeModel(stopGate: gate)
    defer { cleanup() }
    defer { Task { await gate.open() } }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, asked) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    // The in-window Stop & Transcribe (or the menu bar's), held mid-save.
    let stop = Task { await model.stopRecording(title: "Board call") }
    try await waitUntilStopping(model)

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(decision == .terminateLater, "quitting now kills the save midway")
    #expect(asked.withLock { $0 } == 0, "the user already chose to end this recording; there is nothing to ask")
    #expect(model.store.meeting(id: id) == nil, "sanity: not yet saved")
    #expect(lifecycle.shouldTerminate { _ in Issue.record("a second quit was replied to") } == .terminateCancel,
            "a second ⌘Q while waiting owes no second reply")

    await gate.open()
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true])
    #expect(model.store.meeting(id: id)?.title == "Board call", "the meeting was saved before the app quit")
    #expect(await stop.value == id)
}

@MainActor
@Test("A quit while a failing Stop is saving keeps the app open, so the failure stays on screen (F672)")
func aQuitWhileAFailingStopIsSavingStaysOpen() async throws {
    let gate = Gate()
    let (model, cleanup) = try makeModel(stopFails: true, stopGate: gate)
    defer { cleanup() }
    defer { Task { await gate.open() } }
    model.recoverInterruptedRecording = { _ in nil }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let stop = Task { await model.stopRecording(title: "") }
    try await waitUntilStopping(model)
    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }
    try #require(decision == .terminateLater)
    await gate.open()

    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [false], "quitting would take the failure message with it")
    #expect(await stop.value == nil)
    #expect(model.alertMessage?.contains(model.store.recordingDirectoryURL(for: id).path) == true)
}

// MARK: - F808: a quit during a failed stop's rebuild

// A Stop whose finalize fails goes `.idle` and clears the meeting's id, and only then rebuilds the
// meeting from its tracks (`stopRecording`'s catch), with `stopRecording` still running. F672 waited
// only for `.stopping`, so a quit in that window terminated at once, mid-rebuild, and the meeting
// reopened recovered at the next launch instead of saved now. The round-2 review's probes P1 and P2.

/// Holds `stopRecording`'s rebuild, which its catch runs in a detached task through the recovery
/// seam, until the test lets it go. A semaphore because the seam is synchronous; its timeout keeps
/// a failing test from wedging the run.
private final class RebuildGate: @unchecked Sendable {
    private let entered = Locked(false)
    private let release = DispatchSemaphore(value: 0)
    var hasEntered: Bool { entered.withLock { $0 } }
    /// Called from the seam, off the main actor.
    func enterAndWait() {
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 60)
    }
    func open() { release.signal() }
}

/// Polls the gate — the precondition's own subject — against the wall clock.
@MainActor
private func waitUntilRebuilding(_ gate: RebuildGate) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !gate.hasEntered, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(gate.hasEntered, "the failed stop never reached its rebuild")
}

@MainActor
@Test("A quit while a failed Stop is rebuilding the meeting waits for the rebuild, asks nothing, then quits (F808)")
func aQuitDuringAFailedStopsRebuildWaitsForIt() async throws {
    let (model, cleanup) = try makeModel(stopFails: true)
    defer { cleanup() }
    let rebuild = RebuildGate()
    defer { rebuild.open() }
    model.recoverInterruptedRecording = { directory in
        rebuild.enterAndWait()
        return try InterruptedRecordingRecovery.recover(in: directory)
    }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, asked) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let stop = Task { await model.stopRecording(title: "Board call") }
    try await waitUntilRebuilding(rebuild)
    try #require(model.recordingState == .idle, "sanity: the failed stop is idle while it rebuilds")

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }

    try #require(decision == .terminateLater, "quitting now kills the rebuild, and the meeting reopens recovered")
    #expect(asked.withLock { $0 } == 0, "the recording is already ending; there is nothing to ask")
    #expect(model.store.meeting(id: id) == nil, "sanity: not rebuilt yet")
    rebuild.open()
    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true], "the rebuild indexed the meeting, so the quit goes ahead")
    #expect(model.store.meeting(id: id)?.title == "Board call", "indexed before the app quit, with its title")
    #expect(await stop.value == id)
}

@MainActor
@Test("Stop & Quit that finds a failed stop rebuilding waits for the rebuild before it answers (F808)")
func stopAndQuitDuringAFailedStopsRebuildWaitsForIt() async throws {
    let (model, cleanup) = try makeModel(stopFails: true)
    defer { cleanup() }
    let rebuild = RebuildGate()
    defer { rebuild.open() }
    model.recoverInterruptedRecording = { directory in
        rebuild.enterAndWait()
        return try InterruptedRecordingRecovery.recover(in: directory)
    }
    let id = try await startRecordingWithTracks(model)

    let stop = Task { await model.stopRecording(title: "Board call") }
    try await waitUntilRebuilding(rebuild)
    // What Stop & Quit runs once the user answers (`onStopRecordingForQuit`). The realistic route: a
    // sleep's stop began while the question was on screen and failed, and the alert's modal loop kept
    // the main queue running into its rebuild. Created before the rebuild is let go, so it starts first.
    let answer = Task { () -> (mayQuit: Bool, indexed: Bool) in
        let mayQuit = await model.stopRecordingBeforeQuit()
        return (mayQuit, model.store.meeting(id: id) != nil)
    }
    rebuild.open()
    let seen = await answer.value

    #expect(seen.mayQuit)
    #expect(seen.indexed, "Stop & Quit answered while the rebuild was still running")
    #expect(await stop.value == id)
}

@MainActor
@Test("A quit during a failed Stop whose rebuild also fails keeps the app open, so the failure stays on screen (F808)")
func aQuitDuringAFailedRebuildStaysOpen() async throws {
    let (model, cleanup) = try makeModel(stopFails: true)
    defer { cleanup() }
    let rebuild = RebuildGate()
    defer { rebuild.open() }
    // Nothing usable to rebuild. The catch has already cleared `activeMeetingID`, so only the stop's
    // own record of which meeting it was can tell the quit that this folder is still unsaved.
    model.recoverInterruptedRecording = { _ in
        rebuild.enterAndWait()
        return nil
    }
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let stop = Task { await model.stopRecording(title: "") }
    try await waitUntilRebuilding(rebuild)
    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }
    try #require(decision == .terminateLater)
    rebuild.open()

    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [false], "quitting would take the failure message with it")
    #expect(await stop.value == nil)
    #expect(model.alertMessage?.contains(model.store.recordingDirectoryURL(for: id).path) == true)
    #expect(FileManager.default.fileExists(atPath: model.store.recordingDirectoryURL(for: id).path),
            "the folder is kept for a later launch to rebuild")
}

// MARK: - F812: a quit that waited for a Stop & Transcribe

// F673 made Stop & Quit save the meeting without starting its transcription. A quit that instead
// waits (F672) for a Stop & Transcribe already under way let that stop start its job, then quit
// under it, so a cleanly saved meeting reopened "Local transcription was interrupted".

/// A stub engine that never finishes on its own, so a job that started is visibly running.
@MainActor
private func installLatchedEngine(_ model: AppModel, _ engine: Gate) {
    model.runTranscriptionEngineOverride = { _, _ in
        await engine.wait()
        return TranscriptionResult(id: "stub", text: "Done.", languageCode: "en", audioDuration: 2, confidence: nil,
                                   segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "Done.")])
    }
}

@MainActor
@Test("A quit that waited for a Stop & Transcribe leaves the meeting ready to transcribe, without a job it would quit under (F812)")
func aQuitThatWaitedForStopAndTranscribeStartsNoJob() async throws {
    let gate = Gate()
    let (model, cleanup) = try makeModel(stopGate: gate, engineInstalled: true)
    defer { cleanup() }
    defer { Task { await gate.open() } }
    let engine = Gate()
    defer { Task { await engine.open() } }
    installLatchedEngine(model, engine)
    try #require(model.isSelectedEngineInstalled, "sanity: the stub engine counts as installed")
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .keepRecording }
    let atReply = Locked<(quit: Bool, active: Bool, queued: Bool, status: MeetingStatus?)?>(nil)

    // The in-window Stop & Transcribe, held mid-save, and then ⌘Q.
    let stop = Task { await model.stopRecording(title: "Board call") }
    try await waitUntilStopping(model)
    let decision = lifecycle.shouldTerminate { quit in
        atReply.withLock { $0 = (quit, model.hasActiveTranscription, model.isQueuedForTranscription(id),
                                 model.store.meeting(id: id)?.status) }
    }
    try #require(decision == .terminateLater)
    await gate.open()
    let deadline = Date().addingTimeInterval(30)
    while atReply.withLock({ $0 == nil }), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    let seen = try #require(atReply.withLock { $0 }, "the quit was never answered")

    #expect(seen.quit)
    #expect(!seen.active, "a job started now is killed by the quit and the meeting reopens as interrupted")
    #expect(!seen.queued)
    #expect(seen.status == .recorded, "saved, and ready to transcribe at the next launch")
    #expect(await stop.value == id)
    let meeting = try #require(model.store.meeting(id: id))
    #expect(!model.hasActiveTranscription && meeting.status == .recorded, "and nothing starts one after the reply either")
    #expect(meeting.errorMessage == nil, "a cleanly saved meeting, not an interrupted one")
}

@MainActor
@Test("After a quit that waited is cancelled, the next Stop & Transcribe still transcribes (F812 control)")
func theNextStopAfterACancelledQuitStillTranscribes() async throws {
    // The obvious over-fix: a "quit is waiting" mark that outlives its quit. The first stop fails and
    // nothing can be rebuilt, so the quit is cancelled and the app stays open.
    let gate = Gate()
    let (model, cleanup) = try makeModel(stopFails: true, stopGate: gate, engineInstalled: true)
    defer { cleanup() }
    defer { Task { await gate.open() } }
    let engine = Gate()
    defer { Task { await engine.open() } }
    installLatchedEngine(model, engine)
    model.recoverInterruptedRecording = { _ in nil }
    _ = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .keepRecording }
    let replies = Locked<[Bool]>([])

    let failing = Task { await model.stopRecording(title: "") }
    try await waitUntilStopping(model)
    try #require(lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } } == .terminateLater)
    await gate.open()
    try await waitForReply(replies)
    try #require(replies.withLock { $0 } == [false], "sanity: the failed stop cancels the quit")
    try #require(await failing.value == nil)

    // The app stayed open. The next recording's Stop & Transcribe starts its transcription as usual.
    // (A stop resets the engine's injected stop, so this one does not fail.)
    let next = try await startRecordingWithTracks(model)
    #expect(await model.stopRecording(title: "Next") == next)
    #expect(model.hasActiveTranscription || model.isQueuedForTranscription(next),
            "a quit that is over must not keep suppressing transcription")
}

// MARK: - F809: a stop whose stopCapture() never returns

@MainActor
@Test("Stop & Quit whose capture never confirms the stop saves the meeting once the bound runs out, and quits with one reply (F809)")
func stopAndQuitWithAHungStopCaptureQuitsAfterTheBound() async throws {
    // `stopCapture()` never returns. The bound is injected, so nothing here waits it out.
    let neverStops = Gate()
    let (model, cleanup) = try makeModel(stopGate: neverStops)
    defer { cleanup() }
    defer { Task { await neverStops.open() } }
    let bound = Gate()
    defer { Task { await bound.open() } }
    model.recorder.stopCaptureDeadlineForTesting = { await bound.wait() }
    model.recordingTitle = "Late night"
    let id = try await startRecordingWithTracks(model)
    let (lifecycle, _) = makeLifecycle(for: model) { .stopAndQuit }
    let replies = Locked<[Bool]>([])

    let decision = lifecycle.shouldTerminate { quit in replies.withLock { $0.append(quit) } }
    try #require(decision == .terminateLater)
    await bound.open()

    try await waitForReply(replies)
    #expect(replies.withLock { $0 } == [true], "one reply, and it is to quit")
    let meeting = try #require(model.store.meeting(id: id), "saved from what was written, not left for the next launch")
    #expect(meeting.title == "Late night")
    #expect(meeting.status == .recorded)
    #expect(meeting.recoverySource == nil, "finalized normally, not rebuilt after a finishing error")
    #expect(model.recordingState == .idle, "and the Stop button is free again")
    #expect(lifecycle.shouldTerminate { _ in } == .terminateNow, "a later quit is answered at once")
}

// MARK: - The AppKit half, pinned by source (F174: no scene or AppKit harness in this target)

@Test("The app delegate hands every quit to AppLifecycle.shouldTerminate, and init wires its three inputs (F529)")
func theDelegateAndTheAppWireTheQuitDecision() throws {
    let lifecycleSource = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppLifecycle.swift")
    let delegateStart = try #require(lifecycleSource.range(of: "final class AppLifecycleDelegate"))
    let delegate = lifecycleSource[delegateStart.lowerBound...]
    #expect(delegate.contains("func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply"))
    #expect(delegate.contains("lifecycle.shouldTerminate"))
    #expect(delegate.contains("NSApp.reply(toApplicationShouldTerminate:"))

    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let initStart = try #require(entry.range(of: "struct WhisperMeetApp: App {"))
    let bodyStart = try #require(entry.range(of: "var body: some Scene {"))
    let initRegion = entry[initStart.upperBound..<bodyStart.lowerBound]
    // F810: init wires the decision through the function the behaviour tests above call, so what
    // they drive is the app's wiring and not a copy of it.
    for needle in ["lifecycle.wireQuitDuringRecording(to: model)", "QuitDuringRecordingAlert.ask()"] {
        #expect(initRegion.contains(needle), "expected `\(needle)` in WhisperMeetApp.init(), before `body`")
    }
    // The menu bar's Quit must go through AppKit's terminate, which is what reaches the delegate.
    #expect(entry.contains("Button(\"Quit WhisperMeet\") { NSApplication.shared.terminate(nil) }"))
}

@Test("The quit decision's four inputs are assigned in one place only, the function the tests call (F810)")
func theQuitInputsHaveOneWiring() throws {
    // A second assignment anywhere, in init after the call or in any other file, would replace the
    // wiring the behaviour tests check without failing one of them: M6's shape again.
    var assignments: [String: [String]] = [:]
    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        let components = url.pathComponents
        let relative = components[(components.lastIndex(of: "Sources") ?? components.startIndex)...].joined(separator: "/")
        let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8), blankStringLiterals: true)
        for input in ["isRecordingLive", "isRecordingFinishing", "confirmQuitDuringRecording", "onStopRecordingForQuit"] {
            let pattern = #"\b"# + input + #"\s*=(?!=)"#
            let count = (try NSRegularExpression(pattern: pattern))
                .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            if count > 0 { assignments[input, default: []] += Array(repeating: relative, count: count) }
        }
    }
    for input in ["isRecordingLive", "isRecordingFinishing", "confirmQuitDuringRecording", "onStopRecordingForQuit"] {
        #expect(assignments[input] == ["Sources/WhisperMeet/AppEntry.swift"], "\(input): \(assignments[input] ?? [])")
    }
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let wiring = try #require(entry.range(of: "func wireQuitDuringRecording("))
    #expect(entry[wiring.upperBound...].prefix(900).contains("isRecordingFinishing = {"),
            "the one assignment is the wiring function's")
}

/// A Sendable box, since the handlers are closures.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
