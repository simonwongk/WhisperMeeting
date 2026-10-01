import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F292 — the AppModel side, with REAL track writers. The review of the first pass found that every
// AppModel test used an injected engine with no writers, so every Stop still went through the
// recovery branch and the new success path — the one a real dead capture now takes — ran under no
// test at all. These attach the engine's real writers to the meeting's own folder.

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Holds an injected seam until the test lets it go, and says when the seam was reached (F503).
///
/// It replaces sleeping in the seam and sleeping in the test and hoping the two overlapped. Every
/// wait yields rather than blocks, because a seam that blocked a cooperative thread would starve the
/// pool the test needs (`StopUnderHungRestartTests`' `Gate` records that deadlock). It also ends on
/// cancellation, so a test that fails before releasing tears down its `async let` instead of hanging.
private final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var _released = false

    var entered: Bool { lock.withLock { _entered } }

    func enterAndWait() async {
        lock.withLock { _entered = true }
        while !lock.withLock({ _released }), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() { lock.withLock { _released = true } }
}

/// The polled value is the precondition itself, and an exhausted bound fails as the wait it is
/// rather than as a claim about what the test goes on to check (F503).
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(for: .milliseconds(5))
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private struct StreamDied: Error {}
private struct RestartFailed: Error {}

@MainActor
private func makeModel(
    stopping: @escaping () async throws -> Void = {},
    starting: @escaping (URL, @escaping @Sendable (RecordingHealthSnapshot) -> Void,
                         @escaping @Sendable (RecordingMeterSnapshot) -> Void) async throws -> Void = { _, _, _ in },
    restart: @escaping @Sendable (Int64) async throws -> Void = { _ in }
) throws -> (AppModel, URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F292-wiring-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F292.wiring.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let recorder = AudioCaptureEngine(
        stoppingCapture: stopping, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: starting, restartingCapture: restart, directory: root
    )
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") }, qwenInstalled: { true })
    return (model, root, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
private func attachTracks(_ model: AppModel, seconds: Int64) throws -> UUID {
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * seconds, microphone: 48_000 * seconds,
                                       systemStart: 0, microphoneStart: 0)
    return id
}

@MainActor
@Test("Stop after the capture died saves a normal meeting and says the audio ends early (F292)")
func stopAfterDeathSavesANormalMeeting() async throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    await model.startRecording()
    let id = try attachTracks(model, seconds: 13)
    model.recorder.handleStreamFailure(StreamDied())

    #expect(await model.stopRecording(title: "Lid test") == id)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.recordingPath.hasSuffix("meeting.wav"), "went through the recovery rebuild")
    #expect(meeting.errorMessage == nil)
    #expect(meeting.title == "Lid test")
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("could not be restarted"))
    #expect(!alert.contains("finishing error"))
}

@MainActor
@Test("The policy's own finalize is reported once, not again as an early stop (F292)")
func finalizeIsReportedOnce() async throws {
    let (model, _, cleanup) = try makeModel(restart: { _ in throw RestartFailed() })
    defer { cleanup() }
    await model.startRecording()
    let id = try attachTracks(model, seconds: 5)
    model.recorder.handleStreamFailure(StreamDied())

    await model.handleCaptureInterruption(
        trigger: .streamFailed, now: Date().addingTimeInterval(CaptureRestartPolicy.defaultMaximumPaddedGap + 5)
    )

    #expect(!model.recordingState.isLive)
    #expect(model.store.meeting(id: id)?.recordingPath.hasSuffix("meeting.wav") == true)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("Recording stopped and saved"), "the finalize notice was replaced: \(alert)")
    #expect(!alert.contains("could not be restarted, so the saved audio"), "reported twice")
}

@MainActor
@Test("Retries reach the cap even when the capture died before its first health tick (F292)")
func retriesReachTheCapWithoutASeededAliveTime() async throws {
    let (model, _, cleanup) = try makeModel(restart: { _ in throw RestartFailed() })
    defer { cleanup() }
    await model.startRecording()   // no noteCaptureAlive: the recording's start is the anchor
    model.recorder.handleStreamFailure(StreamDied())

    await model.handleCaptureInterruption(trigger: .streamFailed, now: Date().addingTimeInterval(1))
    #expect(model.recordingState.isLive)
    await model.handleCaptureInterruption(
        trigger: .streamFailed, now: Date().addingTimeInterval(CaptureRestartPolicy.defaultMaximumPaddedGap + 30)
    )
    #expect(!model.recordingState.isLive, "measured every gap as 0 and retried forever")
}

@MainActor
@Test("A second Stop while the first is finishing does nothing (F292)")
func secondStopIsIgnored() async throws {
    // The first Stop is held inside the engine until the second has been refused (F503). A 30 ms
    // sleep used to stand in for "the first is in flight". When it was not, the "second" Stop was the
    // one that ran, and `second == nil` still passed, because this engine has no tracks and a Stop
    // that runs returns nil too.
    let stops = Box(0)
    let hold = Hold()
    let (model, _, cleanup) = try makeModel(stopping: {
        let count = stops.with { $0 += 1; return $0 }
        if count == 1 { await hold.enterAndWait() }
    })
    defer { cleanup() }
    await model.startRecording()
    async let first = model.stopRecording(title: "One")
    try await waitUntil("the first Stop to reach the engine") { hold.entered }
    let second = await model.stopRecording(title: "")
    // Before the first is let go: a second Stop that ran would have reached the engine by now.
    #expect(stops.with { $0 } == 1, "the second Stop reached the engine while the first was finishing")
    hold.release()
    _ = await first
    #expect(second == nil)
    #expect(stops.with { $0 } == 1, "a second finalize ran over the first")
}

@MainActor
@Test("Stop while the recording is still starting does nothing (F292)")
func stopWhileStartingIsIgnored() async throws {
    // Driven through the state rather than a slow start: the injected engine returns from
    // `start()` before calling its start closure, so a delay there never runs.
    let stops = Box(0)
    let (model, _, cleanup) = try makeModel(stopping: { stops.with { $0 += 1 } })
    defer { cleanup() }
    await model.startRecording()
    model.setRecordingStateForTesting(.starting)
    #expect(await model.stopRecording(title: "") == nil)
    #expect(stops.with { $0 } == 0, "stopped an engine that was still starting")
    #expect(model.recordingState == .starting)
}

@MainActor
@Test("A display coming back is tried at once, whatever the backoff (F292)")
func displayChangeBypassesBackoff() async throws {
    let attempts = Box(0)
    let (model, _, cleanup) = try makeModel(restart: { _ in
        let n = attempts.with { $0 += 1; return $0 }
        if n == 1 { throw RestartFailed() }
    })
    defer { cleanup() }
    await model.startRecording()
    model.recorder.handleStreamFailure(StreamDied())
    let now = Date()
    await model.handleCaptureInterruption(trigger: .streamFailed, now: now.addingTimeInterval(1))
    await model.handleCaptureInterruption(trigger: .displayReconfigured, now: now.addingTimeInterval(1.5))
    #expect(attempts.with { $0 } == 2, "the display event waited out the tick's backoff")
    #expect(model.captureRestartNotice?.contains("resumed") == true)
}

@MainActor
@Test("The 'keeps trying' banner does not outlive the recording (F292)")
func retryingBannerIsClearedByStop() async throws {
    let (model, _, cleanup) = try makeModel(restart: { _ in throw RestartFailed() })
    defer { cleanup() }
    await model.startRecording()
    model.recorder.handleStreamFailure(StreamDied())
    await model.handleCaptureInterruption(trigger: .streamFailed, now: Date().addingTimeInterval(2))
    #expect(model.captureRestartNotice?.contains("keeps trying") == true)
    _ = await model.stopRecording(title: "")
    #expect(model.captureRestartNotice?.contains("keeps trying") != true)
}

@MainActor
@Test("A restart that finishes while Stop waits announces no resume (F292)")
func resumeIsNotAnnouncedAfterStop() async throws {
    // Held rather than slept (F503). With a 40 ms sleep, a restart that had not begun by then saw
    // `.stopping` and never ran, so the test passed without the case it names ever happening.
    let hold = Hold()
    let finished = Box(false)
    let (model, _, cleanup) = try makeModel(restart: { _ in
        await hold.enterAndWait()
        finished.with { $0 = true }
    })
    defer { cleanup() }
    await model.startRecording()
    model.recorder.handleStreamFailure(StreamDied())
    async let restart: Void = model.handleCaptureInterruption(trigger: .streamFailed, gap: 3)
    try await waitUntil("the restart to reach its seam") { hold.entered }
    try #require(model.recordingState.isLive, "the recording ended before the Stop under test")
    async let stop = model.stopRecording(title: "")
    // Stop leaves `.recording` before its first suspension, so once it has, the Stop began while
    // the restart was still held. Not `== .stopping`, for `stopWaitsForAnInFlightRestart`'s
    // reason: a Stop that does not wait can go through `.stopping` to `.idle` between two polls,
    // and this timed out after 44 s as the wait instead of reaching the claim below.
    try await waitUntil("the Stop to begin") { !model.recordingState.isLive }
    hold.release()
    _ = await (stop, restart)
    try #require(finished.with { $0 }, "the restart never finished, so there was no resume to withhold")
    #expect(model.lastWindowlessMessage?.contains("Recording resumed") != true)
    #expect(model.captureRestartNotice?.contains("resumed") != true)
}

@MainActor
@Test("Stopping from the menu bar or ⌘R keeps the title typed during the recording (F292 review, F298)")
func menuBarStopKeepsTheTypedTitle() async throws {
    // Both call `stopRecording(title: "")` (AppEntry.swift) — the windowless paths, where the
    // typed name is the only way the user will recognise the meeting later.
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    model.recordingTitle = "Board prep"
    await model.startRecording()
    let id = try attachTracks(model, seconds: 2)
    #expect(await model.stopRecording(title: "") == id)
    #expect(model.store.meeting(id: id)?.title == "Board prep")
}

// MARK: - The user's rerun, 2026-09-19 00:18 (F292)
//
// Docked, lid closed: the capture died at 10.7 s, restarted 0.4 s later with the gap padded, and
// then macOS posted `willSleep` — though the Mac never slept — and the app stopped and saved.
// Everything captured was kept, which the user confirmed is the behaviour they want ("once closed,
// just auto save; just don't lose it"). What was missing: nothing said WHY it stopped. The
// window still showed "Recording resumed…", a windowless user's last notification was that
// resume, and the meeting itself carried no reason for being 12 seconds long.

@MainActor
@Test("A lid close that stops the recording says so, replaces the 'resumed' banner, and marks the meeting (F292)")
func sleepStopExplainsItself() async throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    await model.startRecording()
    let id = try attachTracks(model, seconds: 11)
    model.captureRestartNotice = "Recording resumed after the audio capture stopped unexpectedly."

    model.handleSystemWillSleep()
    // Required, not just awaited (F503). The old helper returned either way, so a sleep stop that
    // never finished failed below as "the meeting does not exist", a claim about something else.
    try await waitUntil("the sleep-triggered stop to finish") { model.recordingState == .idle }

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.recordingPath.hasSuffix("meeting.wav"), "a lid close must save normally, not lose the audio")
    #expect(meeting.recoveryInterruption == RecoveryInterruption.systemSleep.rawValue,
            "the meeting does not say why it is short")
    #expect(MeetingStore.recoveryCaveats(for: meeting).contains { $0.contains("closing the lid") })
    let notice = try #require(model.captureRestartNotice)
    #expect(!notice.contains("resumed"), "the stale 'resumed' banner survived the stop")
    #expect(notice.contains("saved"))
    #expect(model.lastWindowlessMessage == notice, "a user with no window was not told it stopped")
}

@MainActor
@Test("A stop the user pressed is not marked as a sleep stop (F292)")
func userStopIsNotASleepStop() async throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    await model.startRecording()
    let id = try attachTracks(model, seconds: 2)
    _ = await model.stopRecording(title: "")
    #expect(model.store.meeting(id: id)?.recoveryInterruption == nil)
}
