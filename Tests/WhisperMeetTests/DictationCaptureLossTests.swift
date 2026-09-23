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
// real input device, so the tap install, `engine.start()` and the happy path remain uncovered. The
// refusals, the drop accounting and the configuration-change response are all reachable, and they
// are what these three tickets are about.

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
    // of every drop — a device mid-change legitimately produces one, and a broken pipeline produces
    // nothing else. The count is what tells those apart afterwards.
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
    let suite = "WhisperMeet.DictationInterruption.\(UUID().uuidString)"
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
    #expect(!recorder.isRecording)
}

@MainActor
@Test("A capture that dropped every buffer is reported as a failure, not as silence (F368)")
func aBrokenCaptureIsNotReportedAsNothingHeard() async throws {
    let suite = "WhisperMeet.DictationDropped.\(UUID().uuidString)"
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
    let suite = "WhisperMeet.DictationSilent.\(UUID().uuidString)"
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
