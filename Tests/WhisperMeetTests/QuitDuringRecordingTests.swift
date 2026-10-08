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

/// The lifecycle exactly as `WhisperMeetApp.init()` wires it, with the question answered by `answer`.
@MainActor
private func makeLifecycle(for model: AppModel, answer: @escaping () -> AppLifecycle.QuitDuringRecordingChoice) -> (AppLifecycle, asked: Locked<Int>) {
    let asked = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.isRecordingLive = { [weak model] in model?.recordingState.isLive ?? false }
    lifecycle.isRecordingFinishing = { [weak model] in model?.recordingState == .stopping }
    lifecycle.confirmQuitDuringRecording = {
        asked.withLock { $0 += 1 }
        return answer()
    }
    lifecycle.onStopRecordingForQuit = { [weak model] in await model?.stopRecordingBeforeQuit() ?? true }
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
    for needle in [
        "lifecycle.isRecordingLive =",
        "lifecycle.confirmQuitDuringRecording =",
        "lifecycle.onStopRecordingForQuit =",
        "lifecycle.isRecordingFinishing =",
        "model?.stopRecordingBeforeQuit()",
        "QuitDuringRecordingAlert.ask()",
    ] {
        #expect(initRegion.contains(needle), "expected `\(needle)` in WhisperMeetApp.init(), before `body`")
    }
    // The menu bar's Quit must go through AppKit's terminate, which is what reaches the delegate.
    #expect(entry.contains("Button(\"Quit WhisperMeet\") { NSApplication.shared.terminate(nil) }"))
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
