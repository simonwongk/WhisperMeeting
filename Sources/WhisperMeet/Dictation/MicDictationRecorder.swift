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
    private(set) var isRecording = false
    var onCaptureInterrupted: (@Sendable (DictationCaptureInterruption) -> Void)?
    private var configurationObserver: (any NSObjectProtocol)?
    /// The node `start()` installed its tap on, so each teardown removes the tap from that node
    /// rather than asking the engine for one (F405). `AVAudioEngine.h`: the engine "creates a
    /// singleton on demand when this property is first accessed", so a teardown written as
    /// `engine.inputNode.removeTap` was, on a recorder that never installed a tap, that first access:
    /// it created the node only to remove a tap that was never there. Set only by `start()`, and
    /// cleared by every teardown.
    private var installedInput: AVAudioInputNode?

    /// Registers the configuration-change observer here rather than in `start()` (F357). The
    /// notification is scoped to this recorder's own engine, and the handler refuses unless a
    /// capture is live, so an observer that outlives a capture costs nothing — while add/remove
    /// around `start`/`stop` would have a window at each edge and two more ways to leak.
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
    private func handleConfigurationChange() {
        guard isRecording else { return }
        log.notice("audio device configuration changed mid-dictation; ending the capture")
        installedInput?.removeTap(onBus: 0)
        installedInput = nil
        engine.stop()
        isRecording = false
        interruption = .deviceConfigurationChanged
        onCaptureInterrupted?(.deviceConfigurationChanged)
    }

    /// Set by `handleConfigurationChange`, read by `stop()` so a key release that races the
    /// notification still reports the reason instead of "nothing heard".
    private var interruption: DictationCaptureInterruption?

    #if DEBUG
    /// Test seams (F357, F368). A real `start()` needs an input device, so these stand in for the
    /// state it would have produced — nothing here is reachable from the app. `setRecordingForTesting`
    /// installs no tap, so `installedInput` stays `nil` and no teardown creates the node (F405).
    var engineForTesting: AVAudioEngine { engine }
    var droppedChunkCountForTesting: Int { processingQueue.sync { droppedChunks } }
    var capturedSampleCountForTesting: Int { processingQueue.sync { sampleBuffer.samples.count } }
    func setRecordingForTesting() { isRecording = true }
    #endif

    /// Which failure an empty capture actually was (F368).
    ///
    /// Pure, and separate from `stop()` because `stop()` cannot run without a device: this is the
    /// rule, and `stop()` below is its only caller.
    static func emptyCaptureFailure(droppedChunks: Int) -> RecorderError {
        droppedChunks > 0 ? .audioConversionFailed(droppedChunks: droppedChunks) : .noAudioCaptured
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard !isRecording else { return }

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
            interruption = nil

            let input = engine.inputNode
            installedInput = input
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
            } catch {
                swiftFailure = error
            }
        }, &raised)

        if formatRefused { throw RecorderError.audioFormatUnavailable }
        if !completed || swiftFailure != nil {
            // Tear down whatever got installed before the failure. `removeTap` on a bus with no
            // tap is a no-op, and `installedInput` is nil if the failure came before the node was
            // reached, so there is nothing to remove. Bridged too (F403): this runs on the engine
            // that just failed, possibly by raising, and `ObjCExceptionBridge.h` says the process
            // state after an exception is undefined. A second raise here is logged, not rethrown —
            // the first failure is the one the user needs to hear about.
            var teardownRaised: NSError?
            let tornDown = WMRunCatchingObjCExceptions({
                installedInput?.removeTap(onBus: 0)
                engine.stop()
            }, &teardownRaised)
            installedInput = nil
            if !tornDown {
                log.error("dictation teardown after a failed start raised: \(teardownRaised?.localizedDescription ?? "no reason", privacy: .public)")
            }
            if let swiftFailure { throw swiftFailure }
            throw RecorderError.captureEngineRaised(
                reason: raised?.localizedDescription ?? "the audio engine could not be started"
            )
        }
        isRecording = true
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
        guard isRecording else { throw RecorderError.notRecording }
        installedInput?.removeTap(onBus: 0)
        installedInput = nil
        engine.stop()
        isRecording = false

        // A device change that landed between the last buffer and this key release already ended
        // the capture; report that rather than whatever the sample count happens to look like
        // (F357). Checked first: an interrupted capture with some audio in it is still an
        // interrupted capture, and pasting its first half is the silent truncation this fixes.
        if let interruption {
            self.interruption = nil
            throw RecorderError.captureInterrupted(interruption)
        }

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
        if isRecording {
            installedInput?.removeTap(onBus: 0)
            installedInput = nil
            engine.stop()
            isRecording = false
        }
        interruption = nil
        processingQueue.sync {
            sampleBuffer.removeAll()
            droppedChunks = 0
        }
    }
}
