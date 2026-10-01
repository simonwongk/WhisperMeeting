import AVFoundation
import ObjCExceptionBridge
import os
import WhisperCore

protocol DictationRecording: AnyObject {
    var isRecording: Bool { get }
    /// Called when the capture has ended on its own and cannot be resumed (F357). Set before
    /// `start`; invoked from a framework-owned thread, so a handler must hop to its own actor.
    var onCaptureInterrupted: (@Sendable (DictationCaptureInterruption) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws
    func stop() throws -> (url: URL, duration: TimeInterval)
    func cancel()
}

/// Mic-only capture for quick dictation. Uses AVAudioEngine (NOT ScreenCaptureKit) so dictation
/// never requires Screen Recording permission. Produces a 16 kHz mono WAV in the temp dir.
///
/// Thread model: the input tap runs on an AVAudioEngine-owned thread; it converts each buffer
/// through a `DictationTapConverter` created per capture and touched only by that thread, then
/// hands the resulting samples to `processingQueue` — the ONLY place `samples` is touched.
/// `stop()`/`cancel()` remove the tap and then drain `processingQueue` (a `sync` barrier) before
/// reading. `removeTap` is not documented to join a tap block already executing, so a chunk enqueued
/// after the drain can still be dropped — bounded at one buffer, which is **~100 ms, not the ~21 ms
/// this comment used to claim** (F359: AVFAudio clamped the 1,024-frame request up to 4,800, and
/// the request now says 4,800). That is the worst-case audio lost at the very end of a dictation,
/// so the correction matters to a user and not only to a reader. Nothing can race the read of
/// `samples` itself. This mirrors the tap+queue+flush
/// discipline `AudioCaptureEngine` already uses, and since F356 it also mirrors the rule that
/// matters more: the capture format is read from each buffer, never pinned ahead of the tap.
final class MicDictationRecorder: DictationRecording, @unchecked Sendable {
    /// `LocalizedError`, like every other error type in both targets (F366). Without it the
    /// Swift-to-NSError bridge answers `localizedDescription` with "The operation couldn't be
    /// completed. (WhisperMeet.MicDictationRecorder.RecorderError error 0.)" — and that string was
    /// used verbatim as the dictation overlay's copy and persisted into `dictation-log.json`, so
    /// the app's own diagnostics recorded a case index instead of what went wrong.
    enum RecorderError: LocalizedError, Equatable {
        case audioFormatUnavailable
        case notRecording
        case noAudioCaptured
        /// Buffers arrived and none of them could be converted (F368). Distinct from
        /// `noAudioCaptured` because the two produce an identical empty sample array and the
        /// controller treats silence as a normal no-op.
        case audioConversionFailed(droppedChunks: Int)
        /// The audio hardware changed under a live capture and the engine stopped itself (F357).
        case captureInterrupted(DictationCaptureInterruption)
        /// AVFoundation raised an `NSException` while the capture was being set up (F374). Before
        /// the ObjC bridge existed this was not an error at all — it was an abort.
        case captureEngineRaised(reason: String)

        var errorDescription: String? {
            switch self {
            case .audioFormatUnavailable:
                // The device-change class F356 and F357 are about. Says what to check, because
                // "unavailable" on its own leaves the user with nothing to do.
                return "No microphone was available. Check that an input device is connected and selected in System Settings › Sound."
            case .notRecording:
                return "Dictation was not recording, so there was nothing to finish."
            case .noAudioCaptured:
                return "No audio was captured."
            case .audioConversionFailed:
                // The count is diagnostic, not copy: "3 chunks" means nothing to the person
                // holding the key down. It reaches the log through `ErrorPresentation.diagnostic`.
                return "The microphone audio could not be processed, so nothing was transcribed."
            case .captureInterrupted(let reason):
                return reason.message
            case .captureEngineRaised:
                // The raised reason ("required condition is false: format.sampleRate ==
                // hwFormat.sampleRate") is diagnostic, not copy — it reaches the log through
                // `ErrorPresentation.diagnostic`, and it is the line the .ips report did not have.
                return "The microphone could not be started because the audio device changed. Try again."
            }
        }
    }

    /// The documented availability probe, injectable so the refusal path can be driven headlessly
    /// (F367). `nil` means read the real hardware format from this recorder's own engine — the one
    /// thing a test must not do, because the first touch of `inputNode` creates the engine's input
    /// node, and that is real CoreAudio work on whatever machine runs the suite (F405).
    typealias HardwareFormatProbe = @Sendable () -> (sampleRate: Double, channels: UInt32)

    private let engine = AVAudioEngine()
    private let injectedFormatProbe: HardwareFormatProbe?
    private let notificationCenter: NotificationCenter
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation.capture")
    private let targetSampleRate = Double(DictationCaptureLimits.sampleRate)
    private let processingQueue = DispatchQueue(label: "com.whispermeet.dictation.mic")
    // The controller normally finalizes at 120 seconds. This independent hard limit prevents the
    // audio queue from growing without bound if the main actor is temporarily unable to fire the
    // watchdog.
    private var sampleBuffer = BoundedAudioSampleBuffer(
        capacity: DictationCaptureLimits.maximumSampleCount
    )
    /// Buffers the converter could not use, counted rather than dropped in silence (F368).
    /// Touched only on `processingQueue`, like `sampleBuffer`.
    private var droppedChunks = 0
    private var configurationObserver: (any NSObjectProtocol)?

    /// Where a capture is (F404). `starting` is the armed state: set before `start()` touches the
    /// hardware, so a configuration change handled while `start()` is still running is recorded
    /// rather than dropped, which `guard isRecording` used to do. Internal rather than private
    /// because `configurationChangeTransition` takes it, and that rule is internal so a test can
    /// call it.
    enum CaptureState { case idle, starting, recording }

    /// Guards every field below it (F404). The configuration-change handler runs on AVFAudio's own
    /// queue ("the callback happens on an internal dispatch queue", `AVAudioEngine.h`) while
    /// `stop()`, `cancel()` and the controller run on main, and these used to be plain stored
    /// properties on an `@unchecked Sendable` class. Held only to read or write them, never across
    /// a call into the engine: the observer is registered with `queue: nil`, so it runs on whatever
    /// thread posts, and a post from inside such a call would try to take a lock its own thread
    /// already holds, which `NSLock` answers by blocking forever.
    private let stateLock = NSLock()
    private var state = CaptureState.idle
    /// Why the capture ended, or why the one being started must not go live (F357, F404).
    ///
    /// `handleConfigurationChange` records it in two states. In `starting` nothing has ended yet:
    /// `start()` reads it when it leaves `starting`, and `startExit` refuses the start on it. In
    /// `recording` it is set in the same critical section that ends the capture, and `stop()` takes
    /// it before its `notRecording` guard, so a key release that lands after the handler has ended
    /// the capture reports the reason, not "not recording". It is cleared by `start()`'s arming and
    /// by its failed exit, and taken or cleared by `stop()` and `cancel()` in every state but
    /// `starting`, which belongs to `start()`. So no capture inherits another's reason.
    ///
    /// It cannot help a key release that lands before the notification has been delivered: that
    /// capture still returns its clip, truncated, as `stop()` explains.
    private var interruption: DictationCaptureInterruption?
    private var interruptionCallback: (@Sendable (DictationCaptureInterruption) -> Void)?
    /// The node `start()` installed its tap on, so each teardown removes the tap from that node
    /// rather than asking the engine for one (F405). `AVAudioEngine.h`: the engine "creates a
    /// singleton on demand when this property is first accessed", so a teardown written as
    /// `engine.inputNode.removeTap` was, on a recorder that never installed a tap, that first access:
    /// it created the node only to remove a tap that was never there. Set only by `start()`, and
    /// taken, under the lock, by whichever teardown ends the capture, so only one of them removes it.
    ///
    /// That holds within one capture, not across two. The handler takes the node and publishes
    /// `idle` under the lock, then removes the tap and stops the engine outside it, and the node is
    /// the engine's singleton. A `start()` that arms in that gap therefore shares bus 0 and the
    /// engine with a teardown still running: its new tap can be removed or its engine stopped under
    /// it, or its `installTap` can meet the old tap still on the bus (`AVAudioNode.h`: "Only one tap
    /// may be installed on any bus"). Reaching that needs a new press during the handler's own
    /// teardown, right after the device changed; the controller itself answers an interruption with
    /// `cancel()`, never with `start()`.
    private var installedInput: AVAudioInputNode?

    var isRecording: Bool { stateLock.withLock { state == .recording } }
    var onCaptureInterrupted: (@Sendable (DictationCaptureInterruption) -> Void)? {
        get { stateLock.withLock { interruptionCallback } }
        set { stateLock.withLock { interruptionCallback = newValue } }
    }

    /// Registers the configuration-change observer here rather than in `start()` (F357). The
    /// notification is scoped to this recorder's own engine, and the handler ignores it unless a
    /// capture is armed or live, so an observer that outlives a capture costs nothing — while
    /// add/remove around `start`/`stop` would have a window at each edge and two more ways to leak.
    /// Registering early closes only the observer's own window; the leading edge also needs
    /// `start()` to arm the capture before it touches the hardware, which it did not until F404.
    init(
        hardwareFormatProbe: HardwareFormatProbe? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.injectedFormatProbe = hardwareFormatProbe
        self.notificationCenter = notificationCenter
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver { notificationCenter.removeObserver(configurationObserver) }
    }

    /// `AVAudioEngine.h`: when the I/O unit "observes a change to the audio input or output
    /// hardware's channel count or sample rate, **the engine stops itself**". Nothing observed
    /// that before F357, so the tap stopped delivering, `isRecording` stayed `true`, and the user
    /// kept talking into a dead engine — getting, on key release, a transcript of only what
    /// preceded the change with no indication anything was lost.
    ///
    /// Ends the capture and says so, rather than restarting and splicing. A resumed capture that
    /// does not say it was resumed re-creates exactly the silent join F275 exists to prevent, and
    /// here there would not even be a padded gap to make the timeline honest.
    ///
    /// Runs on a framework-owned queue. The header warns the engine must not be deallocated here;
    /// it is not — `stop()` on an engine that has already stopped itself is a no-op, and the
    /// recorder holds the only strong reference either way.
    ///
    /// What it does in each state is `configurationChangeTransition` (F404). While `start()` is
    /// still running (`starting`) it only records the reason: `start()` is part-way through its own
    /// bridged block, so it tears down and reports the failure itself, and there is no live capture
    /// yet for the callback to announce.
    private func handleConfigurationChange() {
        let ended: (input: AVAudioInputNode?, callback: (@Sendable (DictationCaptureInterruption) -> Void)?)? =
            stateLock.withLock {
                let transition = MicDictationRecorder.configurationChangeTransition(from: state)
                state = transition.state
                if transition.recordsInterruption { interruption = .deviceConfigurationChanged }
                guard transition.endsCapture else { return nil }
                let input = installedInput
                installedInput = nil
                return (input, interruptionCallback)
            }
        guard let ended else { return }
        log.notice("audio device configuration changed mid-dictation; ending the capture")
        ended.input?.removeTap(onBus: 0)
        engine.stop()
        ended.callback?(.deviceConfigurationChanged)
    }

    #if DEBUG
    /// Test seams (F357, F368, F404). A real `start()` needs an input device, so these stand in for
    /// the state it would have produced or for the calls that need the device — nothing here is
    /// reachable from the app. `setRecordingForTesting` and the hardware step below install no tap,
    /// so `installedInput` stays `nil` and no teardown creates the node (F405).
    var engineForTesting: AVAudioEngine { engine }
    var droppedChunkCountForTesting: Int { processingQueue.sync { droppedChunks } }
    var capturedSampleCountForTesting: Int { processingQueue.sync { sampleBuffer.samples.count } }
    func setRecordingForTesting() { stateLock.withLock { state = .recording } }
    /// For an injected probe to read from inside `start()` (F404). The probe runs between the
    /// arming and the exit, so this is how a test sees that `start()` armed the capture first.
    var captureStateForTesting: CaptureState { stateLock.withLock { state } }

    /// Stands in for the calls in `start()` that need an input device (F404): `engine.inputNode`,
    /// `installTap`, `prepare`, `engine.start()` and the `isRunning` read. It runs where they would,
    /// inside the bridged block after the probe and the buffer reset, and returns what `isRunning`
    /// would have read. A test can then run the rest of the real `start()` (the arming, the probe
    /// and the exit) and post a configuration change while the capture is `starting`. The calls it
    /// replaces still never run under `swift test`; source assertions check parts of them
    /// (`theHardwareCallsAreAllInsideTheBridge`, `startChecksTheEngineIsRunningAfterStartingIt`,
    /// `DictationTapFormatTests`).
    typealias HardwareStartForTesting = @Sendable () -> Bool
    /// Set once, by the init below, before the recorder is shared; `nil` for a recorder built any
    /// other way.
    private var injectedHardwareStart: HardwareStartForTesting?

    /// The probe is required here, not optional: without one, `start()` would read the real
    /// hardware format, which creates the input node (F405).
    convenience init(
        hardwareFormatProbe: @escaping HardwareFormatProbe,
        notificationCenter: NotificationCenter,
        hardwareStartForTesting: @escaping HardwareStartForTesting
    ) {
        self.init(hardwareFormatProbe: hardwareFormatProbe, notificationCenter: notificationCenter)
        injectedHardwareStart = hardwareStartForTesting
    }
    #endif

    /// Which failure an empty capture actually was (F368).
    ///
    /// Pure, and separate from `stop()` because `stop()` cannot run without a device: this is the
    /// rule, and `stop()` below is its only caller.
    static func emptyCaptureFailure(droppedChunks: Int) -> RecorderError {
        droppedChunks > 0 ? .audioConversionFailed(droppedChunks: droppedChunks) : .noAudioCaptured
    }

    /// What a configuration change does in one state (F404): the state it leaves, whether it
    /// records the reason, and whether it ended a live capture. When it did, the handler takes the
    /// node and the callback under the lock, then removes the tap, stops the engine and calls back
    /// outside it.
    struct ConfigurationChangeTransition: Equatable {
        var state: CaptureState
        var recordsInterruption: Bool
        var endsCapture: Bool
    }

    /// The configuration-change handler's rule (F404).
    ///
    /// Pure, and separate from `handleConfigurationChange` for the reason `emptyCaptureFailure` is
    /// separate from `stop()`. The `starting` row is the leading edge. Through the probe alone a
    /// test reaches it only in a start that the probe then refuses or raises in, and either one is
    /// reported ahead of whatever was recorded, so a handler that dropped the change there would
    /// pass. The DEBUG hardware step reaches it in a start that would otherwise succeed, and there
    /// a dropped change lets the capture go live, which `aChangeDuringStartRefusesTheStart` fails on.
    /// The handler is this rule's only caller.
    static func configurationChangeTransition(from state: CaptureState) -> ConfigurationChangeTransition {
        switch state {
        case .idle:
            // Nothing is armed or live, so nothing was interrupted.
            return ConfigurationChangeTransition(state: .idle, recordsInterruption: false, endsCapture: false)
        case .starting:
            // `start()` reads the reason when it leaves `starting` and refuses on it.
            return ConfigurationChangeTransition(state: .starting, recordsInterruption: true, endsCapture: false)
        case .recording:
            return ConfigurationChangeTransition(state: .idle, recordsInterruption: true, endsCapture: true)
        }
    }

    /// How `start()` leaves `starting` once its bridged block has returned (F404).
    enum StartExit {
        /// Go to `recording`. `engineReportedStopped` means `engine.isRunning` read false right
        /// after `engine.start()` returned; `start()` logs that and the capture still goes live.
        case live(engineReportedStopped: Bool)
        /// Go back to `idle`, tear down whatever was installed, and throw this. The Swift error
        /// `engine.start()` threw is carried as it is, which is why this is `any Error`.
        case failed(any Error)
    }

    /// `start()`'s exit rule (F404). Pure, and separate from `start()` for the same reason as
    /// `emptyCaptureFailure`: everything in `start()` after its probe needs a device, so this is the
    /// rule, tested row by row, and `start()` is its only caller. Tests drive `start()`'s use of it
    /// through the probe for the refusal and raise rows, and through the DEBUG hardware step for the
    /// recorded-change and live rows. The Swift-error row is not driven, because the step cannot
    /// throw.
    ///
    /// The checks run in precedence order. A refusal by the probe comes first: nothing after the
    /// probe ran, so the only thing it can coincide with is a recorded change, and its sentence is
    /// the one that says what to check. A Swift error from `engine.start()` comes next, then a
    /// raise, then a change the handler recorded while `starting`. That last one refuses even when
    /// the engine reads running, because the hardware changed while the capture was being set up.
    ///
    /// `engineRunning` refuses nothing on its own. `AVAudioEngine.h` documents `running` only as
    /// "The engine's running state.", and says nothing about when it turns true relative to
    /// `startAndReturnError:` returning. A refusal resting on it would refuse every dictation if it
    /// ever read false on a healthy start. The stop it was meant to catch is caught without it,
    /// because the header says that on a hardware change "the engine stops itself ... and issues
    /// this notification". A notification handled before this exit is the `interruption` row, and
    /// one handled after it finds the capture `recording` and ends it out loud. The one stop only
    /// `engineRunning` would have caught is a stop with no notification. The only such stop the
    /// header describes is auto shutdown, which is "disabled by default" off watchOS and which this
    /// recorder never enables. A start like that now goes live, and the false reading is logged, so
    /// the log can say whether it ever happens.
    static func startExit(
        formatRefused: Bool,
        completed: Bool,
        raisedReason: String?,
        swiftFailure: (any Error)?,
        engineRunning: Bool,
        interruption: DictationCaptureInterruption?
    ) -> StartExit {
        if formatRefused { return .failed(RecorderError.audioFormatUnavailable) }
        if let swiftFailure { return .failed(swiftFailure) }
        if !completed {
            return .failed(RecorderError.captureEngineRaised(
                reason: raisedReason ?? "the audio engine could not be started"
            ))
        }
        if let interruption { return .failed(RecorderError.captureInterrupted(interruption)) }
        return .live(engineReportedStopped: !engineRunning)
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        // Armed before anything touches the hardware (F404), and every failure below returns to
        // `idle`. A configuration change handled from here on is recorded, where it used to be
        // dropped because `isRecording` only became true after `engine.start()` had returned.
        let armed = stateLock.withLock { () -> Bool in
            guard state == .idle else { return false }
            state = .starting
            interruption = nil
            return true
        }
        guard armed else { return }

        // Everything that touches the hardware runs inside `WMRunCatchingObjCExceptions` (F374),
        // and that starts with the availability probe (F403).
        //
        // An exception is not a Swift error, so before F374 the app aborted — which is exactly what
        // happened twice in the field, and what the user saw was the app vanishing. `installTap`
        // raised in F356, and `engine.start()` validates the live device, which AVAudioEngine.h
        // says it answers for an unavailable input by throwing "or an exception", with nothing the
        // caller can decline. The `inputNode` getter is not documented to raise, but its first
        // access does real work, so it is inside the block too.
        //
        // That is why the probe is inside the block: in production it is the FIRST access of
        // `inputNode`. AVAudioEngine.h: the engine "creates a singleton on demand when this
        // property is first accessed". Until F403 the probe ran before this block, so the access
        // that created the node was unbridged, and the bridged `engine.inputNode` below only
        // returned a node that already existed.
        //
        // The Swift `throws` from `engine.start()` is a different channel and is carried out of
        // the block separately: the block cannot itself throw, so swallowing it here would turn a
        // perfectly ordinary error into a success. A refusal by the probe is carried out the same
        // way, as `formatRefused`.
        var formatRefused = false
        var swiftFailure: (any Error)?
        var engineRunning = false
        var raised: NSError?
        let completed = WMRunCatchingObjCExceptions({
            // The documented availability probe, and both halves of it. AVAudioEngine.h,
            // `inputNode`: "Check for the input node's input format (i.e. hardware format) for
            // non-zero sample rate and channel count to see if input is enabled. Trying to perform
            // input through the input node when it is not enabled or available will cause the
            // engine to throw an error (when possible) or an exception." It reads `inputFormat`,
            // not `outputFormat`, because that is the property those sentences name (F358).
            //
            // It narrows the window and cannot close it: the probe is read here and
            // `engine.start()` runs below, so input becoming unavailable in between can still
            // raise — structurally the same read-then-use shape F356 is about. The bridge is what
            // makes that raise an error instead of an abort (F374).
            //
            // Through `hardwareFormat()` so a test can supply the answer (F367), and consulted
            // BEFORE the block's own `engine.inputNode`, so a refusal installs nothing. Read on
            // every start and never cached: F356's whole lesson is that a value read before a
            // side-effecting framework call is already stale, so a value kept between captures is
            // worse again.
            let hardwareFormat = self.hardwareFormat()
            guard
                hardwareFormat.sampleRate > 0,
                hardwareFormat.channels > 0,
                let converter = DictationTapConverter(targetSampleRate: targetSampleRate)
            else {
                formatRefused = true
                return
            }

            processingQueue.sync {
                sampleBuffer.removeAll(keepingCapacity: true)
                droppedChunks = 0
            }

            #if DEBUG
            // A test's stand-in for the rest of this block (see `HardwareStartForTesting`).
            if let injectedHardwareStart {
                engineRunning = injectedHardwareStart()
                return
            }
            #endif

            let input = engine.inputNode
            stateLock.withLock { installedInput = input }
            // `format: nil`, and that is the F356 fix rather than a simplification. AVAudioNode.h
            // documents the argument as "If non-nil, attempts to apply this as the format of the
            // specified output bus" — so a non-nil value is a claim about the hardware, checked against
            // the live device at install time. Enabling the input stream is itself what reconfigures
            // that device, so a format read beforehand is stale by the time it is validated, and
            // AVFAudio answers a mismatch by raising. nil declines to make the claim: the tap delivers
            // the device's own format and `DictationTapConverter` reads it per buffer. Re-reading the
            // format one line earlier would only have shortened the window, not closed it.
            // 4,800 frames — 100 ms at 48 kHz — because that is what AVFAudio delivers anyway
            // (F359). `AVAudioNode.h` documents the parameter's "supported range is [100, 400]
            // ms", and this asked for 1,024 frames: 21.3 ms, a twentieth of the documented
            // minimum. Measured on this Mac rather than inferred from the header:
            //
            //     requested 1,024  (21.3 ms)  -> delivered 4,800   (100.0 ms)
            //     requested 4,800  (100.0 ms) -> delivered 4,800   (100.0 ms)
            //     requested 8,192  (170.7 ms) -> delivered 8,192   (170.7 ms)
            //     requested 19,200 (400.0 ms) -> delivered 19,200  (400.0 ms)
            //
            // So an out-of-range request is silently clamped to the nearest supported value and
            // an in-range one is honoured exactly. This is a no-op in behaviour and the point is
            // that the number now says what happens: the tap fires ten times a second, not fifty.
            //
            // A frame count cannot be in range at every rate — 4,800 is 200 ms at 24 kHz (voice
            // mode), 300 ms at 16 kHz, and 50 ms at 96 kHz. The first two are inside the range;
            // the third is below it and AVFAudio clamps, which is the measured behaviour above
            // rather than an assumption about it.
            input.installTap(onBus: 0, bufferSize: 4_800, format: nil) { [weak self] buffer, _ in
                self?.handleTap(buffer: buffer, converter: converter, onLevel: onLevel)
            }
            engine.prepare()
            do {
                try engine.start()
                // Read for `startExit`, which marks a false reading for the log and does not
                // refuse on it (F404): the header never says `running` is already true when
                // `start()` returns. A hardware change inside this block is caught without it,
                // because the engine "stops itself" and then issues the notification, which the
                // handler records while `starting` or answers by ending the capture once it is
                // `recording`.
                engineRunning = engine.isRunning
            } catch {
                swiftFailure = error
            }
        }, &raised)

        // Leave `starting` in one critical section, so the handler sees either a start that failed
        // or a capture that is live, never a gap between the two. `startExit` is the rule.
        let outcome: (verdict: StartExit, input: AVAudioInputNode?) = stateLock.withLock {
            let verdict = MicDictationRecorder.startExit(
                formatRefused: formatRefused,
                completed: completed,
                raisedReason: raised?.localizedDescription,
                swiftFailure: swiftFailure,
                engineRunning: engineRunning,
                interruption: interruption
            )
            if case .live = verdict {
                state = .recording
                return (verdict, nil)
            }
            // A failed start reports its failure by throwing, so nothing is carried forward for
            // the next capture's key release to report.
            let taken = installedInput
            state = .idle
            installedInput = nil
            interruption = nil
            return (verdict, taken)
        }

        switch outcome.verdict {
        case .live(let engineReportedStopped):
            if engineReportedStopped {
                log.error("audio engine read not running right after a successful start; the capture goes live anyway")
            }
        case .failed(let error):
            // A refusal by the probe came before the node was reached, so nothing was installed.
            if !formatRefused {
                // Tear down whatever got installed before the failure. `removeTap` on a bus with no
                // tap is a no-op, and the taken input is nil if the failure came before the node
                // was reached, so there is nothing to remove. Bridged too (F403): this runs on the
                // engine that just failed, possibly by raising, and `ObjCExceptionBridge.h` says
                // the process state after an exception is undefined. A second raise here is logged,
                // not rethrown — the first failure is the one the user needs to hear about.
                var teardownRaised: NSError?
                let tornDown = WMRunCatchingObjCExceptions({
                    outcome.input?.removeTap(onBus: 0)
                    engine.stop()
                }, &teardownRaised)
                if !tornDown {
                    log.error("dictation teardown after a failed start raised: \(teardownRaised?.localizedDescription ?? "no reason", privacy: .public)")
                }
            }
            throw error
        }
    }

    /// The documented availability probe. AVAudioEngine.h, `inputNode`: "Check for the input
    /// node's input format (i.e. hardware format) for non-zero sample rate and channel count to
    /// see if input is enabled. Trying to perform input through the input node when it is not
    /// enabled or available will cause the engine to throw an error (when possible) **or an
    /// exception**." The guard in `start` narrows that window rather than closing it, because
    /// `engine.start()` runs afterwards (F358, F374).
    ///
    /// Call it only inside `start`'s `WMRunCatchingObjCExceptions` block (F403). With no injected
    /// probe this is the recorder's first access of `inputNode`, the one that creates the node, so
    /// it belongs inside the bridge with every other call that does hardware work.
    ///
    /// It reads `inputFormat`, not `outputFormat`, because that is the property those sentences
    /// name.
    private func hardwareFormat() -> (sampleRate: Double, channels: UInt32) {
        if let injectedFormatProbe { return injectedFormatProbe() }
        let format = engine.inputNode.inputFormat(forBus: 0)
        return (sampleRate: format.sampleRate, channels: format.channelCount)
    }

    /// Runs on the tap thread. Converts the live buffer at whatever format it arrived in, then
    /// hands the samples to `processingQueue` (the engine's buffer is not retained past here).
    ///
    /// Internal rather than private so the drop accounting can be driven without a device (F368);
    /// nothing in the app calls it but the tap closure installed above.
    func handleTap(
        buffer: AVAudioPCMBuffer,
        converter: DictationTapConverter,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        guard let chunk = converter.convert(buffer) else {
            // Counted, not silently dropped (F368). One drop is not an error by itself: tolerating
            // a buffer with no usable frames is defence in depth, and a device that changes rate or
            // channel count mid-capture ends the capture instead (F357). It becomes one when the
            // whole capture yielded nothing and this is non-zero, which `stop()` decides. Without
            // the count, a broken converter and a silent room are the same empty array, and the
            // controller treats the second as a normal no-op.
            processingQueue.async { self.droppedChunks += 1 }
            return
        }
        let level = chunk.level
        processingQueue.async {
            self.sampleBuffer.append(contentsOf: chunk.samples)
            // `level`, not `chunk` — capturing the struct would hold its samples array alive for a
            // main-queue hop to deliver one Float.
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        // One critical section reads and ends the capture, so the handler either ended it first —
        // and left its reason — or finds it already ended and does nothing (F404).
        //
        // What the lock cannot see: an engine that has stopped itself and whose notification has
        // not been delivered yet. A key release in that gap returns the clip without saying it
        // ended early. The audio missing from it is what followed the engine's stop, so it is
        // shorter than that delivery delay, which nobody has measured. `start()` reads
        // `engine.isRunning`, only to log a false reading (see `startExit`); this does not read it
        // at all: here the loss is bounded by that delay, and refusing on it would make every stop
        // after `setRecordingForTesting`, whose engine never ran, report an interruption.
        let ending: (wasRecording: Bool, input: AVAudioInputNode?, interruption: DictationCaptureInterruption?) =
            stateLock.withLock {
                // `starting` belongs to `start()`, which is still running and will settle it.
                guard state != .starting else { return (false, nil, nil) }
                let snapshot = (wasRecording: state == .recording, input: installedInput, interruption: interruption)
                state = .idle
                installedInput = nil
                interruption = nil
                return snapshot
            }
        if ending.wasRecording {
            ending.input?.removeTap(onBus: 0)
            engine.stop()
        }

        // A device change that landed between the last buffer and this key release already ended
        // the capture; report that rather than whatever the sample count happens to look like
        // (F357). Checked first, and before the `notRecording` guard (F404): the handler ending the
        // capture between the controller's `isRecording` read and this call is exactly the race
        // this exists for, and "Dictation was not recording" is the wrong thing to tell the user.
        // An interrupted capture with some audio in it is still an interrupted capture, and pasting
        // its first half is the silent truncation F357 fixes.
        if let interruption = ending.interruption {
            throw RecorderError.captureInterrupted(interruption)
        }
        guard ending.wasRecording else { throw RecorderError.notRecording }

        let (captured, dropped): ([Float], Int) = processingQueue.sync {
            (sampleBuffer.samples, droppedChunks)
        }
        guard !captured.isEmpty else { throw MicDictationRecorder.emptyCaptureFailure(droppedChunks: dropped) }
        if dropped > 0 {
            // Some audio survived, so the clip is worth transcribing — but the gap is real and a
            // support question about a missing sentence needs to find this line.
            log.error("dictation dropped \(dropped, privacy: .public) unconvertible buffers but captured \(captured.count, privacy: .public) samples")
        }

        let data = WAVWriter.wavData(from: captured, sampleRate: Int(targetSampleRate))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try data.write(to: url)
        let duration = Double(captured.count) / targetSampleRate
        return (url, duration)
    }

    func cancel() {
        let ending: (wasRecording: Bool, input: AVAudioInputNode?) = stateLock.withLock {
            // As in `stop()`: a start still running settles its own state.
            guard state != .starting else { return (false, nil) }
            let snapshot = (wasRecording: state == .recording, input: installedInput)
            state = .idle
            installedInput = nil
            interruption = nil
            return snapshot
        }
        if ending.wasRecording {
            ending.input?.removeTap(onBus: 0)
            engine.stop()
        }
        processingQueue.sync {
            sampleBuffer.removeAll()
            droppedChunks = 0
        }
    }
}
