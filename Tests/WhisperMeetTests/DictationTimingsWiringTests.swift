import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F892 — a dictation driven through the controller's headless seams lands in the history with its
// clip length, the recognizer's and the refiner's seconds, and the GPU share before the request,
// and those survive a reload of `dictation-log.json`. The clock is the `dictationClock` seam, moved
// on only by the fake engine and refiner, so the figures are exact rather than whatever this host's
// clock happened to read. (Binary-exact durations, 6.5 s and 1.25 s, so a difference of two clock
// readings equals them exactly.)

/// A clock that moves only when told to.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000
    func now() -> TimeInterval { lock.withLock { seconds } }
    func advance(by delta: TimeInterval) { lock.withLock { seconds += delta } }
}

/// Recognition that takes exactly `seconds` on `clock`.
private struct TimedEngine: DictationEngine {
    let clock: ManualClock
    let seconds: TimeInterval
    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        clock.advance(by: seconds)
        return DictationResult(text: "hello there", languageCode: "en")
    }
    func shutdown() {}
}

/// Recognition that fails after exactly `seconds` on `clock` — a helper that stopped answering.
private struct FailingTimedEngine: DictationEngine {
    let clock: ManualClock
    let seconds: TimeInterval
    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        clock.advance(by: seconds)
        throw LocalWhisperError.processFailed("Dictation helper stopped unexpectedly.")
    }
    func shutdown() {}
}

/// A resident refiner whose pass takes exactly `seconds` on `clock` and refines.
private final class TimedRefiner: DictationTextRefining, @unchecked Sendable {
    private let clock: ManualClock
    private let seconds: TimeInterval
    private let lock = NSLock()
    private var attempts = 0
    var attemptCount: Int { lock.withLock { attempts } }

    init(clock: ManualClock, seconds: TimeInterval) {
        self.clock = clock
        self.seconds = seconds
    }

    func warmUp() async -> Bool { true }
    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        lock.withLock { attempts += 1 }
        clock.advance(by: seconds)
        return RefineAttempt(text: "Hello there.", outcome: .refined)
    }
    func shutdown() {}
}

/// Polls `condition` against a 30 s deadline and requires it.
@MainActor
private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(30)
    while !condition(), SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
private struct Rig {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let recorder: FakeDictationRecorder
    let refiner: TimedRefiner
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init(refine: Bool, gpuBusy: Int?, recognitionFails: Bool = false) throws {
        suite = testSuiteName()
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F892-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(refine, forKey: "dictationRefineEnabled")
        let clock = ManualClock()
        recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav"))
        recorder.stopDuration = 4.0
        refiner = TimedRefiner(clock: clock, seconds: 1.25)
        let engine: any DictationEngine = recognitionFails
            ? FailingTimedEngine(clock: clock, seconds: 6.5)
            : TimedEngine(clock: clock, seconds: 6.5)
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: recorder,
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: refiner,
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.refineRuntimeAvailability = { true }
        controller.clipboardNotifier = {}
        controller.gpuUtilization = { gpuBusy }
        controller.dictationClock = { clock.now() }
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func dictateOnce() async throws -> DictationLogEntry {
        controller.setEnabled(true)
        if defaults.bool(forKey: "dictationRefineEnabled") {
            try await waitFor("the refiner to be resident") { controller.isRefinerReady }
        }
        monitor.onPressStart?()
        try await waitFor("the capture to start") { recorder.isRecording }
        monitor.onPressEnd?()
        try await waitFor("the dictation to reach the history") { !controller.logStore.log.entries.isEmpty }
        return try #require(controller.logStore.log.entries.first)
    }
}

@MainActor
@Test("A refined dictation lands in the history with its clip, recognizer and refiner seconds and the GPU share (F892)")
func aRefinedDictationRecordsItsTimings() async throws {
    let rig = try Rig(refine: true, gpuBusy: 28)
    defer { rig.tearDown() }

    let entry = try await rig.dictateOnce()

    #expect(entry.text == "Hello there.")
    #expect(entry.refinement == DictationRefinement.refined.rawValue)
    #expect(entry.timings == DictationTimings(
        clipSeconds: 4.0, transcribeSeconds: 6.5, refineSeconds: 1.25, gpuBusyPercent: 28
    ))
    // On disk, not only in memory: a fresh store over the same directory reads them back.
    let reloaded = DictationLogStore(directory: rig.directory)
    #expect(reloaded.log.entries.first?.timings == entry.timings)
}

@MainActor
@Test("A dictation the refiner was not asked about records no refiner time (F892)")
func anUnrefinedDictationHasNoRefinerTime() async throws {
    // At the F890 threshold the refiner is not consulted: its time is unmeasured, not zero.
    let rig = try Rig(refine: true, gpuBusy: DictationController.refineSkipGPUBusyPercent)
    defer { rig.tearDown() }

    let entry = try await rig.dictateOnce()

    #expect(rig.refiner.attemptCount == 0)
    #expect(entry.refinement == DictationRefinement.rawGPUBusy.rawValue)
    #expect(entry.timings == DictationTimings(
        clipSeconds: 4.0, transcribeSeconds: 6.5, refineSeconds: nil,
        gpuBusyPercent: DictationController.refineSkipGPUBusyPercent
    ))
}

@MainActor
@Test("With refinement off and the GPU unreadable, the history keeps the clip and recognizer seconds only (F892)")
func refinementOffAndAnUnreadableGPU() async throws {
    let rig = try Rig(refine: false, gpuBusy: nil)
    defer { rig.tearDown() }

    let entry = try await rig.dictateOnce()

    #expect(entry.text == "hello there")
    #expect(entry.timings == DictationTimings(clipSeconds: 4.0, transcribeSeconds: 6.5))
}

@MainActor
@Test("A dictation whose recognition fails keeps its clip, its seconds until the failure and the GPU share (F892 review)")
func aFailedDictationRecordsItsTimings() async throws {
    // Review finding (b): a recognizer that times out is the slowest dictation of all and the one a
    // user reports as "it hung", and `fail` recorded it with no figures, so the report never saw it.
    let rig = try Rig(refine: true, gpuBusy: 28, recognitionFails: true)
    defer { rig.tearDown() }

    let entry = try await rig.dictateOnce()

    guard case .failed = entry.outcome else {
        Issue.record("expected a failed entry, got \(entry.outcome)")
        return
    }
    #expect(rig.refiner.attemptCount == 0)
    #expect(entry.timings == DictationTimings(clipSeconds: 4.0, transcribeSeconds: 6.5, gpuBusyPercent: 28))
}

@MainActor
@Test("A NaN set on a timing after construction cannot stop the history from being saved (F892 review)")
func aNaNSetLaterCannotStopTheHistorySaving() throws {
    // The review reproduced it through the real store: the entry stayed in the in-memory log, so
    // every later save threw too, and the history stopped being saved for the rest of the session.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F892-nan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DictationLogStore(directory: directory)

    var timings = DictationTimings(clipSeconds: 1)
    timings.clipSeconds = .nan
    store.record(text: "first", outcome: .pasted, timings: timings)
    #expect(store.saveErrorMessage == nil, "the entry with a NaN figure could not be saved")
    store.record(text: "second", outcome: .pasted)
    #expect(store.saveErrorMessage == nil, "a later dictation could not be saved either")

    let expected: [String] = ["second", "first"]
    #expect(DictationLogStore(directory: directory).log.entries.map(\.text) == expected)
}
