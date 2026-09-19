import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F275 — the app wiring for the restart path.
//
// `CaptureRestartPolicyTests` pins the decision table; this pins that `AppModel` asks it, acts on
// the answer, and tells the user. Driven through `handleCaptureInterruption` over a real temp
// `MeetingStore`, with the capture engine's injection seams standing in for a display and a
// microphone.
//
// **The case that matters most has no power event at all.** A lid close on a *docked* Mac kills the
// display-bound `SCStream` and the machine never sleeps, so `willSleep` never fires and neither does
// `didWake`. The recording simply stays "running" while nothing is captured — which is what happened
// to 63 minutes of the user's meeting. The trigger that catches it is the display reconfiguration,
// or the health monitor noticing the dead stream, and that is why the restart cannot be hung off the
// sleep notifications alone.

/// A Sendable box, since the restart seam is `@Sendable` and the assertions run on the main actor.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

@MainActor
private func makeRestartModel(
    restart: @escaping @Sendable (Int64) async throws -> Void = { _ in }
) throws -> (AppModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptureRestartWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F275.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let recorder = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: restart,
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
@Test("A dead stream on a docked lid close is restarted, and the user is told (F275)")
func deadStreamIsRestartedAndAnnounced() async throws {
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(
        trigger: .displayReconfigured,
        gap: 12,
        now: Date(timeIntervalSince1970: 1_757_000_500)
    )

    // Explicitly `Int64`, not an inferred literal. Swift 6.3 infers `[12 * 48_000]` as `[Int64]`
    // from context here; the CI runner's 6.1.0 does not, and typed it `[Int]` — so this compiled
    // locally and failed on `macos-15`. Exactly the divergence F270 exists for: the developer
    // toolchain is always newer than the runner's, so a green local gate cannot see this class.
    let expectedFrames: [Int64] = [12 * 48_000]
    #expect(padded.withLock { $0 } == expectedFrames, "the gap was not padded with silence")
    #expect(model.recordingState.isLive, "the recording was ended instead of resumed")
    let notice = try #require(model.captureRestartNotice)
    #expect(notice.contains("silence"))
    #expect(notice.contains("12 sec"))
}

@MainActor
@Test("A live stream is left alone — no padding, no notice (F275)")
func liveStreamIsUntouched() async throws {
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    // No `handleStreamFailure`: plugging in a monitor reconfigures the displays without killing a
    // capture pinned to the main one.
    await model.handleCaptureInterruption(trigger: .displayReconfigured, gap: 0, now: Date())

    #expect(padded.withLock { $0 }.isEmpty)
    #expect(model.captureRestartNotice == nil)
    #expect(model.recordingState.isLive)
}

@MainActor
@Test("A gap past the cap finalizes the recording rather than padding hours of nothing (F275)")
func longGapFinalizesTheRecording() async throws {
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(
        trigger: .didWake,
        gap: CaptureRestartPolicy.defaultMaximumPaddedGap + 60,
        now: Date()
    )

    #expect(padded.withLock { $0 }.isEmpty, "padded a gap the policy said to finalize")
    #expect(!model.recordingState.isLive, "an over-cap gap must end the recording")
    let notice = try #require(model.captureRestartNotice)
    #expect(notice.contains("saved"))
}

@MainActor
@Test("Restarts are bounded, and the bound saves the audio rather than abandoning it (F275)")
func restartsAreBounded() async throws {
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    for _ in 0..<CaptureRestartPolicy.defaultMaximumRestarts {
        model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
        await model.handleCaptureInterruption(trigger: .streamFailed, gap: 1, now: Date())
    }
    #expect(padded.withLock { $0 }.count == CaptureRestartPolicy.defaultMaximumRestarts)
    #expect(model.recordingState.isLive)

    // A display that is gone for good must stop the spinning — by saving, not by giving up.
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
    await model.handleCaptureInterruption(trigger: .streamFailed, gap: 1, now: Date())

    #expect(padded.withLock { $0 }.count == CaptureRestartPolicy.defaultMaximumRestarts,
            "kept restarting past the bound")
    #expect(!model.recordingState.isLive)
}

@MainActor
@Test("An interruption with no recording running does nothing (F275)")
func idleInterruptionIsIgnored() async throws {
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.handleCaptureInterruption(trigger: .didWake, gap: 30, now: Date())

    #expect(padded.withLock { $0 }.isEmpty)
    #expect(model.captureRestartNotice == nil)
}

@MainActor
@Test("A padded resume is recorded in the sidecar, so recovery knows the timeline was patched (F275)")
func paddedResumeIsRecordedInTheSidecar() async throws {
    let (model, root, defaults, suite) = try makeRestartModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    let at = Date(timeIntervalSince1970: 1_757_000_900)
    await model.handleCaptureInterruption(trigger: .didWake, gap: 45, now: at)

    // If the app is killed after a padded resume, startup recovery rebuilds from the raw tracks —
    // and must not describe a patched timeline as a clean capture.
    let session = try #require(RecordingSessionSidecar.read(
        in: model.store.recordingDirectoryURL(for: id)
    ))
    #expect(session.paddedGaps.count == 1)
    #expect(session.paddedGaps.first?.seconds == 45)
    #expect(session.paddedGaps.first?.resumedAt == at)
}

@MainActor
@Test("Overlapping triggers restart once, not once per trigger (F275)")
func overlappingTriggersRestartOnce() async throws {
    // The 1 Hz health tick fires `.streamFailed` every second while the stream is dead, and the
    // display and wake notifications can land in the same window. `handleCaptureInterruption` is
    // async, so without a guard two calls both observe `hasStreamError == true` before either has
    // restarted — and the recording gets padded twice for one gap, which shifts the timeline by the
    // gap all over again. Exactly the defect padding exists to prevent.
    let padded = Locked<[Int64]>([])
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        // Slow enough that a second trigger lands mid-restart, which is the real ordering.
        try? await Task.sleep(for: .milliseconds(120))
        padded.withLock { $0.append(frames) }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    async let first: Void = model.handleCaptureInterruption(trigger: .streamFailed, gap: 5)
    async let second: Void = model.handleCaptureInterruption(trigger: .displayReconfigured, gap: 5)
    async let third: Void = model.handleCaptureInterruption(trigger: .didWake, gap: 5)
    _ = await (first, second, third)

    #expect(padded.withLock { $0 }.count == 1, "one gap was padded more than once")
}

@MainActor
@Test("A gap is recorded only once the restart actually succeeded (F275)")
func failedRestartRecordsNoPaddedGap() async throws {
    // The sidecar is what tells startup recovery the timeline was patched. Writing the gap before
    // the restart is attempted means a failed restart leaves a claim that silence was inserted when
    // none was — and recovery would then describe a clean set of tracks as patched.
    struct RestartFailed: Error {}
    let (model, root, defaults, suite) = try makeRestartModel(restart: { _ in
        throw RestartFailed()
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(trigger: .streamFailed, gap: 20, now: Date())

    let session = RecordingSessionSidecar.read(in: directory)
    #expect(session?.paddedGaps.isEmpty != false, "recorded a gap that was never padded")
    // F292: and it no longer ends the meeting. The 2026-09-18 lid-close trace showed the first
    // restart is attempted about a second after the death — often while the display is still
    // coming back — and one failure used to save and end a meeting that had minutes to recover.
    #expect(model.recordingState.isLive, "one failed restart ended the recording")
}

@MainActor
@Test("A failed restart is retried after a backoff, and the retry pads the whole gap once (F292)")
func failedRestartIsRetriedWithBackoff() async throws {
    struct RestartFailed: Error {}
    let attempts = Locked<[Int64]>([])
    let failuresLeft = Locked(2)
    let (model, root, defaults, suite) = try makeRestartModel(restart: { frames in
        attempts.withLock { $0.append(frames) }
        if failuresLeft.withLock({ left in defer { left -= 1 }; return left > 0 }) { throw RestartFailed() }
    })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let start = Date(timeIntervalSince1970: 1_757_000_000)
    model.noteCaptureAlive(at: start)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(trigger: .streamFailed, now: start.addingTimeInterval(1))   // fails
    await model.handleCaptureInterruption(trigger: .streamFailed, now: start.addingTimeInterval(2))   // backing off
    #expect(attempts.withLock { $0.count } == 1, "retried on every tick instead of backing off")

    await model.handleCaptureInterruption(trigger: .streamFailed, now: start.addingTimeInterval(4))   // fails again
    await model.handleCaptureInterruption(trigger: .streamFailed, now: start.addingTimeInterval(20))  // succeeds
    #expect(attempts.withLock { $0.count } == 3)
    #expect(model.recordingState.isLive)
    // The successful attempt pads the whole outage, measured from the last time the capture was
    // alive — not just the time since the previous failed attempt.
    // Typed, for the reason `deadStreamIsRestartedAndAnnounced` gives: an inferred literal compares
    // as a different integer type and fails while both sides print 960000.
    let wholeGap: Int64 = 20 * 48_000
    #expect(attempts.withLock { $0.last } == wholeGap)
    #expect(model.captureRestartNotice?.contains("20 sec") == true)
    #expect(model.recorder.restartCount == 1, "failed attempts must not spend the restart budget")
}

@MainActor
@Test("Retries end at the padding cap by saving the recording, not by giving up silently (F292)")
func retriesEndAtThePaddingCap() async throws {
    struct RestartFailed: Error {}
    let (model, root, defaults, suite) = try makeRestartModel(restart: { _ in throw RestartFailed() })
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    await model.startRecording()
    let start = Date(timeIntervalSince1970: 1_757_000_000)
    model.noteCaptureAlive(at: start)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(trigger: .streamFailed, now: start.addingTimeInterval(1))
    #expect(model.recordingState.isLive)
    await model.handleCaptureInterruption(
        trigger: .streamFailed, now: start.addingTimeInterval(CaptureRestartPolicy.defaultMaximumPaddedGap + 1)
    )
    #expect(!model.recordingState.isLive, "a capture gone past the cap must be saved")
    #expect(model.captureRestartNotice?.contains("saved") == true)
}

@MainActor
@Test("Stop during an in-flight restart waits for it instead of racing the engine (F292)")
func stopWaitsForAnInFlightRestart() async throws {
    let events = Locked<[String]>([])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F292-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F292.race.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let recorder = AudioCaptureEngine(
        stoppingCapture: { events.withLock { $0.append("stop") } },
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in
            events.withLock { $0.append("restart-began") }
            try? await Task.sleep(for: .milliseconds(200))
            events.withLock { $0.append("restart-ended") }
        },
        directory: root
    )
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") }, qwenInstalled: { true })
    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    async let restart: Void = model.handleCaptureInterruption(trigger: .streamFailed, gap: 2)
    try await Task.sleep(for: .milliseconds(50))
    _ = await model.stopRecording(title: "")
    _ = await restart

    #expect(events.withLock { $0 } == ["restart-began", "restart-ended", "stop"])
}

@MainActor
@Test("A resumed recording is announced to a user with no window, and the risk alert re-arms (F292, F294)")
func resumeIsAnnouncedWindowless() async throws {
    let (model, root, defaults, suite) = try makeRestartModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    await model.startRecording()
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
    await model.handleCaptureInterruption(trigger: .streamFailed, gap: 8, now: Date())

    // `lastWindowlessMessage` records what was *offered* to the windowless channel, before the
    // has-a-window check — so this proves the resume went through `report`, not that a notification
    // was posted. Posting needs `NSApp`, which a headless test does not have (F344).
    let sent = try #require(model.lastWindowlessMessage, "the resume never reached the windowless channel")
    #expect(sent.contains("Recording resumed"))
    #expect(model.alertMessage == nil, "a successful resume is news, not an alert to dismiss")
}

// MARK: - F284: three writers, each clobbering the others' fields

@MainActor
@Test("A sleep after a padded gap does not erase the gap (F284)")
func sleepDoesNotEraseAPaddedGap() async throws {
    // Found by whisper-62 while checking whether the sidecar could carry F283's signal, rather than
    // assuming it could. `noteSleepInterruption` and `persistRecordingSession` each construct a
    // FRESH `RecordingSession` and call the whole-file `write` without reading, so they erase
    // whatever the other writers put there.
    //
    // The lost sleep marker is not the worst of it. Startup recovery reads `paddedGaps` to choose a
    // rebuild's alignment, so a dropped gap makes a patched timeline describe itself as clean —
    // F282's defect reachable again, through a lost field rather than through the label logic that
    // ticket fixed. A recording that sleeps, resumes, then sleeps again does it today.
    let (model, root, defaults, suite) = try makeRestartModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.addLiveMarker(label: "pricing")
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    await model.handleCaptureInterruption(trigger: .didWake, gap: 20, now: Date())
    #expect(RecordingSessionSidecar.read(in: directory)?.paddedGaps.count == 1)

    // Now sleep. Under the bug this rewrote the file from scratch.
    model.handleSystemWillSleep(now: Date(timeIntervalSince1970: 1_757_100_000))

    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.paddedGaps.count == 1, "the sleep note erased the padded gap")
    #expect(session.interruptedBySleepAt != nil, "the sleep was not noted")
    #expect(session.markers.count == 1, "the marker was lost too")
}

@MainActor
@Test("Two padded gaps both survive (F284)")
func twoPaddedGapsBothSurvive() async throws {
    let (model, root, defaults, suite) = try makeRestartModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)

    for gap in [11.0, 23.0] {
        model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
        await model.handleCaptureInterruption(trigger: .streamFailed, gap: gap, now: Date())
    }

    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.paddedGaps.map(\.seconds) == [11, 23])
}

@MainActor
@Test("A marker dropped after a padded gap does not erase it (F284)")
func aMarkerDoesNotEraseAPaddedGap() async throws {
    // `persistRecordingSession` is the third caller and the one a user triggers most often.
    let (model, root, defaults, suite) = try makeRestartModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    let directory = model.store.recordingDirectoryURL(for: id)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
    await model.handleCaptureInterruption(trigger: .streamFailed, gap: 7, now: Date())

    model.addLiveMarker(label: "after the gap")

    let session = try #require(RecordingSessionSidecar.read(in: directory))
    #expect(session.paddedGaps.count == 1, "adding a marker erased the padded gap")
    #expect(session.markers.count == 1)
}
