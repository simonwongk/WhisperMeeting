import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F367, F368, F357 — three ways a dictation capture can end badly, none of which the suite could
// see before this file.
//
// `grep -rn MicDictationRecorder Tests/` used to find nothing. The type had no initializer, its
// engine was a `private let` built inline, and its format came from that engine — so every line of
// `start()` was unexecuted by `swift test`, and the controller's failure handling was well tested
// through a fake and **unreachable in the real failure**. A green suite reasonably read as "the
// start-failure path is covered".
//
// What still cannot be driven here, stated once rather than implied: a successful `start()` needs a
// real input device, so the input node, the tap install, `engine.start()` and the `isRunning` read
// never run. The refusals, the drop accounting and the configuration-change response are all
// reachable, and they are what these three tickets are about. Where a decision on the unreachable
// path matters, it is a pure rule tested row by row instead: `emptyCaptureFailure` (F368), and
// `startExit` and `configurationChangeTransition` (F404). Since F404 a DEBUG hardware step stands in
// for those device calls, so the rest of a successful `start()` (its arming, its probe and its exit)
// and a change handled while it runs are driven for real.

/// `@Sendable` closures need a reference to count into.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// For a probe that needs the recorder it was injected into: a strong reference from the probe
/// would be a cycle, since the recorder keeps its probe.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - F367, the format probe

@Test("An unavailable input refuses the capture before anything is installed (F367)")
func anUnavailableInputRefusesTheCapture() throws {
    let probes = Counter()
    let recorder = MicDictationRecorder(hardwareFormatProbe: {
        probes.increment()
        return (sampleRate: 0, channels: 0)
    })

    #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
        try recorder.start(onLevel: { _ in })
    }
    #expect(probes.count == 1, "the documented probe is the guard; it must run exactly once")
    #expect(!recorder.isRecording, "a refused start must not leave the recorder believing it captures")
}

@Test("Each half of the documented probe refuses on its own (F367)")
func eitherHalfOfTheProbeRefuses() throws {
    // AVAudioEngine.h asks for "non-zero sample rate AND channel count". A guard that checked only
    // one would pass this suite if the other were dropped, which is how a two-clause guard becomes
    // a one-clause guard in a later edit.
    for probed in [(sampleRate: 48_000.0, channels: UInt32(0)), (sampleRate: 0.0, channels: UInt32(1))] {
        let recorder = MicDictationRecorder(hardwareFormatProbe: { probed })
        #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
            try recorder.start(onLevel: { _ in })
        }
    }
}

@Test("The probe is read per start, never pinned across them (F367)")
func theProbeIsReadOnEveryStart() throws {
    // F356's lesson as a test: a value read before a side-effecting framework call is stale by the
    // time the call validates it, so it must never be cached between captures. Two starts, two
    // reads, and the second answer is a different one.
    let answers = Box<[(sampleRate: Double, channels: UInt32)]>([
        (sampleRate: 0, channels: 0),
        (sampleRate: 0, channels: 2),
    ])
    let probes = Counter()
    let recorder = MicDictationRecorder(hardwareFormatProbe: {
        probes.increment()
        var remaining = answers.value
        let next = remaining.removeFirst()
        answers.value = remaining
        return next
    })
    for _ in 0..<2 {
        #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
            try recorder.start(onLevel: { _ in })
        }
    }
    #expect(probes.count == 2)
}

@Test("A probe that raises is caught by the bridge, and the recorder survives for the next press (F403)")
func aRaisingProbeIsCaughtByTheBridge() throws {
    // In production the probe is `engine.inputNode.inputFormat(forBus: 0)`, and it is the FIRST
    // access of `inputNode` — the one `AVAudioEngine.h` says "creates a singleton on demand". It
    // used to run before F374's bridge, so a raise there was the abort F356 was, not an error.
    // Before F403 this test took the whole test process down with it.
    let calls = Counter()
    let recorder = MicDictationRecorder(hardwareFormatProbe: {
        calls.increment()
        if calls.count == 1 {
            NSException(name: .invalidArgumentException, reason: "probe raised", userInfo: nil).raise()
        }
        return (sampleRate: 0, channels: 0)
    })

    #expect(throws: MicDictationRecorder.RecorderError.captureEngineRaised(reason: "probe raised")) {
        try recorder.start(onLevel: { _ in })
    }
    #expect(!recorder.isRecording, "a start that raised must not leave the recorder believing it captures")
    // The engine is a `let` reused by every later press, so the next press must reach the probe
    // again and get its ordinary answer rather than a stuck state.
    #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
        try recorder.start(onLevel: { _ in })
    }
    #expect(calls.count == 2)
}

// MARK: - F368, a dropped buffer is counted

@Test("A capture that heard nothing is silence only when nothing was dropped (F368)")
func theEmptyCaptureVerdictDistinguishesSilenceFromLoss() {
    // The rule `stop()` applies. "Nothing heard" and "the converter refused every buffer" produce
    // an identical empty sample array, and the controller treats the first as a normal no-op —
    // overlay `.empty`, `outcome: .empty`. Treating a broken pipeline that way is what makes the
    // failure undiagnosable in the field.
    #expect(MicDictationRecorder.emptyCaptureFailure(droppedChunks: 0) == .noAudioCaptured)
    #expect(
        MicDictationRecorder.emptyCaptureFailure(droppedChunks: 7)
            == .audioConversionFailed(droppedChunks: 7)
    )
}

@Test("A buffer the converter cannot use is counted, not silently discarded (F368)")
func droppedBuffersAreCounted() throws {
    let recorder = MicDictationRecorder(hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) })
    let converter = try #require(DictationTapConverter(targetSampleRate: 16_000))
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
    )
    // `frameLength` left at 0: the converter yields no frames and returns nil, which is the shape
    // of every drop — an isolated one is tolerated, and a broken pipeline produces nothing else. The
    // count is what tells those apart afterwards.
    let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
    for _ in 0..<3 { recorder.handleTap(buffer: empty, converter: converter, onLevel: { _ in }) }

    #expect(recorder.droppedChunkCountForTesting == 3)
    #expect(recorder.capturedSampleCountForTesting == 0)

    // A usable buffer is not counted as a drop, or the counter would condemn every capture.
    let sine = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    sine.frameLength = 4_800
    let channel = try #require(sine.floatChannelData?[0])
    for index in 0..<4_800 {
        channel[index] = 0.2 * sin(2 * .pi * 440 * Float(index) / 48_000)
    }
    recorder.handleTap(buffer: sine, converter: converter, onLevel: { _ in })
    #expect(recorder.droppedChunkCountForTesting == 3)
    #expect(recorder.capturedSampleCountForTesting > 0)
}

// MARK: - F357, the device changes mid-capture

@Test("A configuration change while idle is ignored (F357)")
func aConfigurationChangeWhileIdleIsIgnored() {
    let center = NotificationCenter()
    let interruptions = Box<[DictationCaptureInterruption]>([])
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center
    )
    recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }

    center.post(name: .AVAudioEngineConfigurationChange, object: recorder.engineForTesting)
    #expect(interruptions.value.isEmpty, "nothing was being captured, so nothing was interrupted")
}

@Test("A configuration change mid-capture ends the capture and says so (F357)")
func aConfigurationChangeEndsTheCapture() {
    // `AVAudioEngine.h`: when the I/O unit "observes a change to the audio input or output
    // hardware's channel count or sample rate, the engine stops itself". Nothing observed that, so
    // the tap stopped delivering, `isRecording` stayed true, and the user kept talking into a dead
    // engine — getting, on key release, a transcript of only what preceded the change, with no
    // indication anything was lost.
    let center = NotificationCenter()
    let interruptions = Box<[DictationCaptureInterruption]>([])
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center
    )
    recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }
    recorder.setRecordingForTesting()

    center.post(name: .AVAudioEngineConfigurationChange, object: recorder.engineForTesting)

    #expect(interruptions.value == [.deviceConfigurationChanged])
    #expect(!recorder.isRecording, "the engine stopped itself; the recorder must not claim otherwise")
}

@Test("Only this recorder's own engine can interrupt it (F357)")
func anotherEnginesChangeIsNotOurs() {
    let center = NotificationCenter()
    let interruptions = Box<[DictationCaptureInterruption]>([])
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center
    )
    recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }
    recorder.setRecordingForTesting()

    center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
    #expect(interruptions.value.isEmpty, "a meeting capture's engine must not end a dictation")
}

// MARK: - F404, the handler and stop() agree on what happened

@Test("A key release after the change still reports the change, not 'not recording' (F404)")
func aStopAfterTheChangeReportsTheInterruption() {
    // Interleaving (a): the controller reads `isRecording` as true, the handler ends the capture on
    // AVFAudio's queue, and then `stop()` runs. `stop()` used to check `isRecording` before the
    // interruption, so it threw `.notRecording` — "Dictation was not recording, so there was
    // nothing to finish." went to the overlay and to `dictation-log.json`, and the controller's own
    // interruption handler then found the session already failed and said nothing. An observer
    // registered with `queue: nil` runs inside `post`, so this order is exact, not a timing hope.
    let center = NotificationCenter()
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center
    )
    recorder.setRecordingForTesting()
    center.post(name: .AVAudioEngineConfigurationChange, object: recorder.engineForTesting)

    #expect(throws: MicDictationRecorder.RecorderError.captureInterrupted(.deviceConfigurationChanged)) {
        _ = try recorder.stop()
    }
    // Reported once. A second stop is a stop with nothing behind it, and the next capture must not
    // inherit this one's reason.
    #expect(throws: MicDictationRecorder.RecorderError.notRecording) {
        _ = try recorder.stop()
    }
}

@Test("A change while start() is still running does not leak into a later capture (F404)")
func aChangeDuringARefusedStartIsNotCarriedForward() {
    // The probe runs inside start(), so it can post the notification while the capture is armed
    // but not yet recording: the leading edge F404 is about. The probe then refuses, so start()
    // must report its own refusal, must not call back as if a live capture had ended, and must not
    // leave the interruption behind for the next capture's key release to report.
    let center = NotificationCenter()
    let interruptions = Box<[DictationCaptureInterruption]>([])
    let engine = Box<AVAudioEngine?>(nil)
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: {
            center.post(name: .AVAudioEngineConfigurationChange, object: engine.value)
            return (sampleRate: 0, channels: 0)
        },
        notificationCenter: center
    )
    engine.value = recorder.engineForTesting
    recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }

    #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
        try recorder.start(onLevel: { _ in })
    }
    #expect(!recorder.isRecording)
    #expect(interruptions.value.isEmpty, "start() reports its own failure; no live capture ended")

    recorder.setRecordingForTesting()
    #expect(throws: MicDictationRecorder.RecorderError.noAudioCaptured) {
        _ = try recorder.stop()
    }
}

// MARK: - F404's leading edge, as rules

/// What `engine.start()` threw, in a row where it threw. Any error that is not a `RecorderError`
/// can stand in for it, because the rule's job is to hand that error back unchanged.
private struct EngineStartFailed: Error {}

/// A `StartExit` in a form `#expect` can compare. `StartExit.failed` carries `any Error`, which is
/// not `Equatable`, because the error `engine.start()` threw is passed through as it is.
private enum StartVerdict: Equatable {
    case live(engineReportedStopped: Bool)
    case recorderError(MicDictationRecorder.RecorderError)
    case engineStartError
    case otherError(String)
}

private func verdict(of exit: MicDictationRecorder.StartExit) -> StartVerdict {
    switch exit {
    case .live(let engineReportedStopped): return .live(engineReportedStopped: engineReportedStopped)
    case .failed(let error as MicDictationRecorder.RecorderError): return .recorderError(error)
    case .failed(is EngineStartFailed): return .engineStartError
    case .failed(let error): return .otherError(String(describing: error))
    }
}

/// One row of `startExit`: what start()'s bridged block left behind, and what start() must do.
private struct StartExitRow {
    var name: String
    var formatRefused = false
    var completed = true
    var raisedReason: String? = nil
    var engineStartThrew = false
    var engineRunning = false
    var interruption: DictationCaptureInterruption? = nil
    var expected: StartVerdict
}

@Test("start() leaves `starting` by one rule, and a change recorded while starting refuses the start (F404)")
func startExitRows() {
    // A successful `engine.start()` needs an input device, so start()'s exit is tested as the rule
    // it applies, as F368's `emptyCaptureFailure` is for stop(). Each row is a state the bridged
    // block can leave behind. F404's leading edge is the three rows after the raises: a change the
    // handler recorded while `starting` refuses the start whether or not the engine still reads
    // running, and an engine that reads not running with nothing recorded goes live and is only
    // reported, because nothing documents when `isRunning` turns true.
    let changed = DictationCaptureInterruption.deviceConfigurationChanged
    let rows = [
        StartExitRow(name: "the probe refused", formatRefused: true,
                     expected: .recorderError(.audioFormatUnavailable)),
        StartExitRow(name: "the probe refused after a change was recorded", formatRefused: true,
                     interruption: changed, expected: .recorderError(.audioFormatUnavailable)),
        StartExitRow(name: "engine.start() threw", engineStartThrew: true,
                     expected: .engineStartError),
        StartExitRow(name: "engine.start() threw after a change was recorded", engineStartThrew: true,
                     interruption: changed, expected: .engineStartError),
        StartExitRow(name: "a call raised", completed: false, raisedReason: "probe raised",
                     expected: .recorderError(.captureEngineRaised(reason: "probe raised"))),
        StartExitRow(name: "a call raised with no reason", completed: false,
                     expected: .recorderError(.captureEngineRaised(reason: "the audio engine could not be started"))),
        StartExitRow(name: "a call raised after a change was recorded", completed: false,
                     raisedReason: "probe raised", interruption: changed,
                     expected: .recorderError(.captureEngineRaised(reason: "probe raised"))),
        StartExitRow(name: "started and running, with a change recorded while starting", engineRunning: true,
                     interruption: changed, expected: .recorderError(.captureInterrupted(changed))),
        StartExitRow(name: "started but not running, with a change recorded while starting",
                     interruption: changed, expected: .recorderError(.captureInterrupted(changed))),
        StartExitRow(name: "started but not running, with nothing recorded",
                     expected: .live(engineReportedStopped: true)),
        StartExitRow(name: "started and running, with nothing recorded", engineRunning: true,
                     expected: .live(engineReportedStopped: false)),
    ]
    for row in rows {
        let thrown: (any Error)? = row.engineStartThrew ? EngineStartFailed() : nil
        let exit = MicDictationRecorder.startExit(
            formatRefused: row.formatRefused,
            completed: row.completed,
            raisedReason: row.raisedReason,
            swiftFailure: thrown,
            engineRunning: row.engineRunning,
            interruption: row.interruption
        )
        #expect(verdict(of: exit) == row.expected, "\(row.name)")
    }
}

@Test("A configuration change is recorded while start() runs, and ends only a live capture (F404)")
func configurationChangeTransitionRows() {
    // The handler's rule in each state. `starting` is the leading edge: start() is part-way through
    // its bridged block, so the reason is recorded for `startExit` to refuse on, and the handler
    // neither tears down nor calls back, because there is no live capture yet to announce.
    typealias Transition = MicDictationRecorder.ConfigurationChangeTransition
    #expect(MicDictationRecorder.configurationChangeTransition(from: .idle)
            == Transition(state: .idle, recordsInterruption: false, endsCapture: false))
    #expect(MicDictationRecorder.configurationChangeTransition(from: .starting)
            == Transition(state: .starting, recordsInterruption: true, endsCapture: false))
    #expect(MicDictationRecorder.configurationChangeTransition(from: .recording)
            == Transition(state: .idle, recordsInterruption: true, endsCapture: true))
}

@Test("start() arms the capture before the probe, the first call that touches the hardware (F404)")
func startArmsTheCaptureBeforeTheProbe() throws {
    // The one leading-edge mechanism neither rule can see is the ORDER. The probe is the first
    // statement inside start()'s bridged block (F403), so the state it observes is the state every
    // hardware call after it runs in. A change handled in `idle` is dropped, which was F404's
    // window; in `starting` it is recorded, and `startExit` refuses on it.
    let recorder = WeakBox<MicDictationRecorder>()
    let seen = Box<MicDictationRecorder.CaptureState?>(nil)
    let made = MicDictationRecorder(hardwareFormatProbe: {
        seen.value = recorder.value?.captureStateForTesting
        return (sampleRate: 0, channels: 0)
    })
    recorder.value = made
    try #require(made.captureStateForTesting == .idle)

    #expect(throws: MicDictationRecorder.RecorderError.audioFormatUnavailable) {
        try made.start(onLevel: { _ in })
    }
    #expect(seen.value == .starting, "the probe ran before start() armed the capture")
    // A start left in `starting` would make every later start() return without starting, and the
    // controller reads a start() that does not throw as a capture that began.
    #expect(made.captureStateForTesting == .idle, "a refused start must disarm")
}

@Test("start() reads isRunning after starting the engine, and start() and the handler decide through their rules (F404)")
func startChecksTheEngineIsRunningAfterStartingIt() throws {
    // The rules above are worth having only if the recorder uses them. The tests after this one
    // drive start()'s exit and the handler for real, but through the DEBUG hardware step, which
    // replaces the calls from `engine.inputNode` to the `isRunning` read. So this source assertion
    // stays for what they skip: that isRunning is read after engine.start() and reaches the rule,
    // and that a false reading is logged. A successful `engine.start()` needs an input device and
    // `swift test` must never need one: F306's precedent for an entry point the harness cannot drive.
    let source = try recorderSourceForBraceMatching()
    let start = try #require(
        declarationBody("func start(onLevel: @escaping @Sendable (Float) -> Void) throws {", in: source),
        "start() not found; did it move?"
    )
    let started = try #require(start.range(of: "try engine.start()"), "start() no longer starts the engine")
    let afterStart = start[started.upperBound...]
    #expect(afterStart.contains("engineRunning = engine.isRunning"),
            "nothing reads engine.isRunning after engine.start() returns")
    let exitCall = try #require(afterStart.range(of: "startExit("), "start() no longer leaves `starting` through startExit")
    let arguments = afterStart[exitCall.upperBound...].prefix { $0 != ")" }
    #expect(arguments.contains("engineRunning: engineRunning"), "startExit is not told what isRunning read")
    #expect(arguments.contains("interruption: interruption"), "startExit is not told what the handler recorded")
    // A live start whose engine read not running is reported, not dropped in silence. The slice
    // runs to the first closing brace, which is the end of that `if`, so both must be inside it.
    let live = try #require(afterStart.range(of: "case .live(let engineReportedStopped):"))
    let liveCase = afterStart[live.upperBound...].prefix { $0 != "}" }
    #expect(liveCase.contains("if engineReportedStopped {"), "a live start ignores what isRunning read")
    #expect(liveCase.contains("log.error("), "a live start over a stopped engine is not logged")

    let handler = try #require(
        declarationBody("func handleConfigurationChange() {", in: source),
        "handleConfigurationChange() not found; did it move?"
    )
    #expect(handler.contains("configurationChangeTransition(from: state)"), "the handler does not decide through its rule")
}

// MARK: - F404's leading edge, through the real start()

// The rules above say what start() and the handler should decide; these check that they do. The
// DEBUG hardware step stands in for the calls in start() that need an input device (the node, the
// tap, `prepare`, `engine.start()` and the `isRunning` read), at the point they would run: after
// the probe and the arming, inside the bridge, before the exit. Everything else is the real code.
// An observer registered with `queue: nil` runs inside `post`, so a change posted from the step is
// handled before the step returns, while start() is still `starting`. AVFAudio posts from its own
// queue, so a real change lands before start()'s exit or after it; the first and third tests below
// are those two cases. Neither runs two threads at once.

@Test("A configuration change during start()'s hardware calls refuses the start, through the real exit (F404)")
func aChangeDuringStartRefusesTheStart() {
    // F404's defect as behaviour: a change handled before start() returned used to be dropped,
    // and the capture went live into an engine that had stopped itself. Both readings of
    // `isRunning`, because the change refuses the start whatever the engine reads afterwards.
    for engineRunning in [false, true] {
        let center = NotificationCenter()
        let interruptions = Box<[DictationCaptureInterruption]>([])
        let engine = Box<AVAudioEngine?>(nil)
        let steps = Counter()
        let recorder = MicDictationRecorder(
            hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
            notificationCenter: center,
            hardwareStartForTesting: {
                steps.increment()
                center.post(name: .AVAudioEngineConfigurationChange, object: engine.value)
                return engineRunning
            }
        )
        engine.value = recorder.engineForTesting
        recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }

        #expect(throws: MicDictationRecorder.RecorderError.captureInterrupted(.deviceConfigurationChanged),
                "isRunning read \(engineRunning)") {
            try recorder.start(onLevel: { _ in })
        }
        #expect(steps.count == 1, "the hardware step did not run, so nothing was posted while starting")
        #expect(!recorder.isRecording, "a refused start must not leave the recorder believing it captures")
        #expect(interruptions.value.isEmpty, "start() reports its own failure; no live capture ended")
        // Reported once, by start(). The next key release must not report it again.
        #expect(throws: MicDictationRecorder.RecorderError.notRecording) {
            _ = try recorder.stop()
        }
    }
}

@Test("A start with no configuration change goes live through the real exit, whatever isRunning reads (F404)")
func aStartWithNoChangeGoesLive() throws {
    // The control for the test above, and F404's decision as behaviour: a false `isRunning` with
    // nothing recorded goes live (start() logs it) rather than refusing, because nothing documents
    // when it turns true.
    for engineRunning in [true, false] {
        let recorder = MicDictationRecorder(
            hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
            notificationCenter: NotificationCenter(),
            hardwareStartForTesting: { engineRunning }
        )
        try recorder.start(onLevel: { _ in })
        #expect(recorder.isRecording, "isRunning read \(engineRunning)")
        // A live capture that heard nothing ends as `noAudioCaptured`, not `notRecording`.
        #expect(throws: MicDictationRecorder.RecorderError.noAudioCaptured) {
            _ = try recorder.stop()
        }
        // The step stands in for every call that needs a device, so the engine never made its
        // input node (observed through `attachedNodes`, as the F405 test below does).
        #expect(!recorder.engineForTesting.attachedNodes.contains { $0 is AVAudioInputNode })
    }
}

@Test("A configuration change after start() has gone live ends the capture and says so (F357, F404)")
func aChangeAfterALiveStartEndsTheCapture() throws {
    let center = NotificationCenter()
    let interruptions = Box<[DictationCaptureInterruption]>([])
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center,
        hardwareStartForTesting: { true }
    )
    recorder.onCaptureInterrupted = { reason in interruptions.value.append(reason) }
    try recorder.start(onLevel: { _ in })
    try #require(recorder.isRecording)

    center.post(name: .AVAudioEngineConfigurationChange, object: recorder.engineForTesting)

    #expect(interruptions.value == [.deviceConfigurationChanged])
    #expect(!recorder.isRecording, "the engine stopped itself; the recorder must not claim otherwise")
    #expect(throws: MicDictationRecorder.RecorderError.captureInterrupted(.deviceConfigurationChanged)) {
        _ = try recorder.stop()
    }
}

// MARK: - F405, a teardown must not create the node it tears down

private let recorderSourcePath = "Sources/WhisperMeet/Dictation/MicDictationRecorder.swift"

/// The recorder's source with comments stripped (F285) and string literals blanked, so a brace in
/// a comment or a literal cannot move a declaration's end.
private func recorderSourceForBraceMatching() throws -> String {
    SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url(recorderSourcePath), encoding: .utf8),
        blankStringLiterals: true
    )
}

/// The body of the declaration whose head is `head`, which must end with its opening brace, so a
/// protocol requirement of the same name, which has no body, cannot match. The source must have
/// had its string literals blanked, or a `{` inside one would be counted as a scope.
private func declarationBody(_ head: String, in source: String) -> Substring? {
    guard let found = source.range(of: head), head.hasSuffix("{") else { return nil }
    var depth = 1
    var cursor = found.upperBound
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return source[found.upperBound..<cursor] }
        default: break
        }
        cursor = source.index(after: cursor)
    }
    return nil
}

@Test("Ending a capture that never installed a tap never creates the input node (F405)")
func endingWithoutATapCreatesNoInputNode() throws {
    // `AVAudioEngine.h`: the engine "creates a singleton on demand when this property is first
    // accessed". A teardown written as `engine.inputNode.removeTap` was therefore the first access
    // on a recorder whose tap was never installed, and did real CoreAudio work on whatever machine
    // ran it to remove a tap that did not exist. `attachedNodes` is where the created node shows.
    func hasInputNode(_ recorder: MicDictationRecorder) -> Bool {
        recorder.engineForTesting.attachedNodes.contains { $0 is AVAudioInputNode }
    }
    let probe: MicDictationRecorder.HardwareFormatProbe = { (sampleRate: 48_000, channels: 1) }

    let center = NotificationCenter()
    let interrupted = MicDictationRecorder(hardwareFormatProbe: probe, notificationCenter: center)
    try #require(!hasInputNode(interrupted), "a fresh engine has no input node until one is asked for")
    interrupted.setRecordingForTesting()
    center.post(name: .AVAudioEngineConfigurationChange, object: interrupted.engineForTesting)
    #expect(!hasInputNode(interrupted), "the configuration-change handler created the input node")

    let stopped = MicDictationRecorder(hardwareFormatProbe: probe)
    stopped.setRecordingForTesting()
    // It throws, because nothing was captured; which error it throws is not this test's subject.
    _ = try? stopped.stop()
    #expect(!hasInputNode(stopped), "stop() created the input node")

    let cancelled = MicDictationRecorder(hardwareFormatProbe: probe)
    cancelled.setRecordingForTesting()
    cancelled.cancel()
    #expect(!hasInputNode(cancelled), "cancel() created the input node")
}

@Test("No teardown path asks the engine for its input node (F405)")
func theTeardownPathsDoNotReachForTheInputNode() throws {
    // The source-level twin of the test above, with a different blind spot: that one depends on
    // AVFAudio listing a lazily created node in `attachedNodes`, which is observed rather than
    // documented; this one depends only on the text. Each teardown removes the tap from the node
    // `start()` installed it on, so a recorder that installed nothing touches nothing.
    let source = try recorderSourceForBraceMatching()
    for head in [
        "func handleConfigurationChange() {",
        "func stop() throws -> (url: URL, duration: TimeInterval) {",
        "func cancel() {",
    ] {
        let body = try #require(declarationBody(head, in: source), "\(head) not found; did it move?")
        #expect(!body.contains("engine.inputNode"), "\(head) asks the engine for its input node")
    }
}

// MARK: - the controller's side of F357 and F368

@MainActor
private func makeInterruptibleController(
    recorder: FakeDictationRecorder,
    defaults: UserDefaults,
    directory: URL
) -> (DictationController, FakeHotkeyMonitor) {
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    controller.clipboardNotifier = {}
    return (controller, monitor)
}

@MainActor
@Test("A device change mid-capture leaves a stated failure, not a listening overlay (F357)")
func aDeviceChangeEndsTheSessionInAStatedState() async throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationInterruption-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
    let (controller, monitor) = makeInterruptibleController(
        recorder: recorder, defaults: defaults, directory: directory
    )
    monitor.onPressStart?()
    try #require(controller.status == .listening)
    let togglesBefore = monitor.resetToggleCount
    let cancelsBefore = recorder.cancelCount

    recorder.simulateCaptureInterruption()
    for _ in 0..<200 where controller.status == .listening {
        try await Task.sleep(for: .milliseconds(5))
    }

    guard case .error(let message) = controller.status else {
        Issue.record("expected a stated failure, got \(controller.status)")
        return
    }
    #expect(message == DictationCaptureInterruption.deviceConfigurationChanged.message)
    // The latch, for the same reason the watchdog clears it (F78): this ended with no user
    // end-edge, so a toggle-mode press afterwards must start a capture rather than fire a no-op
    // end edge into an already-failed session.
    #expect(monitor.resetToggleCount > togglesBefore)
    // The recorder is released (F405). `!recorder.isRecording` cannot show that, because the fake
    // clears it itself before calling back, so this counts the `cancel()` instead.
    #expect(recorder.cancelCount > cancelsBefore, "the controller did not release the recorder")
    // And the history says so, which is where a support question starts: F357 promised that
    // `dictation-log.json` records `failed`, and until F405 nothing read it back.
    let entries = DictationLogStore(directory: directory).log.entries
    #expect(entries.count == 1)
    #expect(entries.first?.outcome == .failed(DictationCaptureInterruption.deviceConfigurationChanged.message))
}

@MainActor
@Test("A capture that dropped every buffer is reported as a failure, not as silence (F368)")
func aBrokenCaptureIsNotReportedAsNothingHeard() async throws {
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationDropped-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
    recorder.stopError = MicDictationRecorder.RecorderError.audioConversionFailed(droppedChunks: 12)
    let (controller, monitor) = makeInterruptibleController(
        recorder: recorder, defaults: defaults, directory: directory
    )
    monitor.onPressStart?()
    try #require(controller.status == .listening)
    monitor.onPressEnd?()

    for _ in 0..<200 where controller.status == .listening {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard case .error = controller.status else {
        Issue.record("a broken converter must not read as 'nothing heard': \(controller.status)")
        return
    }

    // And the persisted history says so too, which is where a support question starts.
    let entries = DictationLogStore(directory: directory).log.entries
    #expect(entries.count == 1)
    guard case .failed(let recorded)? = entries.first?.outcome else {
        Issue.record("expected a failed outcome, got \(String(describing: entries.first?.outcome))")
        return
    }
    #expect(!recorded.contains("couldn't be completed"), "\(recorded)")
}

@MainActor
@Test("A genuinely silent capture is still a no-op, not a failure (F368)")
func silenceIsStillSilence() async throws {
    // The control. F368's change is only worth having if it did not turn every quiet press into
    // an error dialog — which is the obvious way to over-fix it.
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationSilent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav"))
    recorder.stopError = MicDictationRecorder.RecorderError.noAudioCaptured
    let (controller, monitor) = makeInterruptibleController(
        recorder: recorder, defaults: defaults, directory: directory
    )
    monitor.onPressStart?()
    try #require(controller.status == .listening)
    monitor.onPressEnd?()

    for _ in 0..<200 where controller.status == .listening {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.status == .idle, "\(controller.status)")
    let entries = DictationLogStore(directory: directory).log.entries
    #expect(entries.count == 1)
    #expect(entries.first?.outcome == .empty)
}
