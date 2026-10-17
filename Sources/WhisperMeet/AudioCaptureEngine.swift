import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ObjCExceptionBridge
import os
import OSLog
import ScreenCaptureKit
import WhisperCore

struct RecordingArtifact: Sendable {
    let mixedRecordingURL: URL
    let systemTrackURL: URL
    let microphoneTrackURL: URL
    let duration: TimeInterval
    /// The capture's health rollup (nil when no monitor ran, e.g. an injected test capture). Surfaced
    /// on the meeting as a channel-level advisory (F79).
    let healthReport: RecordingHealthReport?
    /// The capture died before Stop and was not revived, so the audio ends before the recording
    /// did (F292). The file is still a normal, aligned finalize of everything captured.
    var captureStoppedEarly = false
    /// What `source-tracks.json` says beyond the frame counts, for the session sidecar (F753), so a
    /// manifest this stop failed to write can be written later without inventing alignment.
    var capturedAlignment: RecordingSession.CapturedAlignment?
}

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case noDisplayAvailable
    case noAudioCaptured
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermissionDenied:
            return "Screen & System Audio Recording access is required. Enable WhisperMeet in System Settings, then quit WhisperMeet completely with ⌘Q and open it again."
        case .noDisplayAvailable:
            return "No display is available for system-audio capture."
        case .noAudioCaptured:
            return "No microphone or system audio was captured."
        case let .conversionFailed(message):
            return "The recording could not be prepared: \(message)"
        }
    }
}

final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let targetSampleRate = 48_000.0

    /// The capture sample rate, for callers that must convert a duration to frames — F275's padding
    /// has to use exactly the rate the tracks were written at or the gap is the wrong length.
    static var captureSampleRate: Double { targetSampleRate }

    /// The health tick's cadence (`startHealthTimer`), exposed so `AppModel` can derive a
    /// conservative restart-padding estimate from it (F460) instead of a second literal `1`
    /// describing the same interval in a different file.
    static let healthTickInterval: TimeInterval = 1.0

    /// How long Stop waits for capture work it does not control before it goes on without it: an
    /// in-flight restart (`AppModel.waitForCaptureRestartToSettle`, F292 and F365), and the stream's
    /// own `stopCapture()` (F809).
    ///
    /// One bound, not a second guess. `SCStream.h` gives `stopCaptureWithCompletionHandler:` no time
    /// limit, so nothing measured says how long a stop may take. A restart tears its dead stream down
    /// with the same call before it builds another, and Stop has waited up to this long for a whole
    /// restart since F292, so a `stopCapture()` gets the same. The figure itself is F292's choice,
    /// not a measurement.
    static let captureSettleBound: Duration = .seconds(10)
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.whispermeet.app",
        category: "RecordingStartup"
    )

    private let captureQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.whispermeet.audio-capture", qos: .userInitiated)
        #if DEBUG
        queue.setSpecific(key: AudioCaptureEngine.captureQueueKeyForTesting, value: true)
        #endif
        return queue
    }()
    #if DEBUG
    /// Marks `captureQueue` so a test can ask where a callback ran (F632) — `dispatchPrecondition`
    /// can only trap, not answer.
    private static let captureQueueKeyForTesting = DispatchSpecificKey<Bool>()
    /// Whether the calling code is running on `captureQueue` (F632).
    static var isOnCaptureQueueForTesting: Bool {
        DispatchQueue.getSpecific(key: captureQueueKeyForTesting) == true
    }
    #endif

    /// The live capture stream, or nil.
    ///
    /// Stored behind `captureQueue` like `_streamError`, `_streamDied` and `_pendingRestartPadding`
    /// (F334, and F364 for the first two — the sentence was false for them until then). `start()`,
    /// `stop()`, `cancel()` and `restartAfterFailure` reach it from off the queue — all four are
    /// `nonisolated async`, so under SE-0338 they run on the generic executor whichever actor
    /// called them, and genuinely in parallel — and the sample handler reaches it from the capture
    /// queue. Code already on that queue uses `_stream` directly; a `sync` from the queue would
    /// deadlock.
    private var _stream: SCStream?
    private var stream: SCStream? {
        get { captureQueue.sync { _stream } }
        set { captureQueue.sync { _stream = newValue } }
    }
    /// The two track writers, behind `captureQueue` for F334's reason and F365's (F364 did the
    /// same for `_streamError`/`_streamDied`). On the queue, the sample handler and
    /// `applyPendingRestartPaddingIfNeeded` write through them — `restartAfterFailure` reaches
    /// them only that way, inside its own `captureQueue.sync` — `finishTrackWriters` (F388) and
    /// `preservePartialTracks` (F632) finish them, `discardTrackWriters` (F734) discards them, and
    /// `reset` drops them inside its `sync`. Off the queue, through the accessors below: `start`
    /// and `stop`, which are `nonisolated async` and so run on the generic executor, not on their
    /// callers' MainActor (SE-0338), and the DEBUG test seams. An unsynchronized load/store of a
    /// strong reference can over-release, and this one is a `FloatTrackWriter` holding an open
    /// descriptor.
    ///
    /// **Code already on `captureQueue` must use the `_` storage; a `sync` from the queue
    /// deadlocks.** Converted site by site for that reason, never by rename.
    private var _systemWriter: FloatTrackWriter?
    private var systemWriter: FloatTrackWriter? {
        get { captureQueue.sync { _systemWriter } }
        set { captureQueue.sync { _systemWriter = newValue } }
    }
    private var _microphoneWriter: FloatTrackWriter?
    private var microphoneWriter: FloatTrackWriter? {
        get { captureQueue.sync { _microphoneWriter } }
        set { captureQueue.sync { _microphoneWriter = newValue } }
    }
    private var sessionDirectory: URL?
    private var startedAt: Date?
    /// Any capture failure: a stream death, or one buffer failing to convert or write.
    ///
    /// F364: this and `_streamDied` were plain stored properties while the comment on `_stream`
    /// above declared them queue-protected — false for both, and read from three threads. They now
    /// follow the same `_`-storage-plus-accessor pattern as `_stream`. **Code already on
    /// `captureQueue` must use the `_` storage; a `sync` from the queue deadlocks.**
    private var _streamError: Error?
    private var streamError: Error? {
        get { captureQueue.sync { _streamError } }
        set { captureQueue.sync { _streamError = newValue } }
    }
    /// The stream itself stopped — as opposed to one buffer failing to convert or write, which also
    /// sets `_streamError` (F292). Only a real death means the audio ends early, and only a real
    /// death may tear a live capture down to restart it (F363).
    ///
    /// Every write also publishes the value to `streamDiedMirror` (F401), for `captureDidDie`. The
    /// `didSet` does that, not the write sites, so a new write cannot forget it. The flag is still
    /// owned by the queue. `stop()` reads it together with `_restartInProgress` and `_stream` in one
    /// queue block, and the restart clears and restores it together with `_streamError`. Only the
    /// queue keeps those combinations atomic.
    private var _streamDied = false {
        didSet { streamDiedMirror.withLock { $0 = _streamDied } }
    }
    /// A read-only copy of `_streamDied` for readers that must not wait for `captureQueue` (F401).
    /// That queue also runs the sample handler and all track I/O, including a restart's whole owed
    /// padding in one block: 394–515 ms for the 5-minute cap on an M3 Pro's internal SSD. A
    /// `captureQueue.sync` read from the MainActor waited out all of it. Only `_streamDied`'s
    /// `didSet` writes it, and the lock guards only the copy, never any queue state.
    private let streamDiedMirror = OSAllocatedUnfairLock(initialState: false)
    private var streamDied: Bool {
        get { captureQueue.sync { _streamDied } }
        set { captureQueue.sync { _streamDied = newValue } }
    }
    /// Bumped by every `reset()` (F292). A restart remembers the value it started under and, after
    /// each of its awaits, gives up if a stop or cancel has reset the engine in the meantime —
    /// otherwise a restart outliving Stop's bounded wait would start a stream nothing ever stops,
    /// and the next recording's `start()` would find `stream != nil` and silently do nothing.
    private var _sessionGeneration = 0
    private var sessionGeneration: Int { captureQueue.sync { _sessionGeneration } }
    /// A restart is between tearing down the dead stream and paying its padding (F292). A stop that
    /// lands then — only possible once Stop's bounded wait has run out — is stopping a capture that
    /// had died, and must not treat a half-started stream's refusal to stop as a finishing failure.
    private var _restartInProgress = false
    private var restartInProgress: Bool {
        get { captureQueue.sync { _restartInProgress } }
        set { captureQueue.sync { _restartInProgress = newValue } }
    }
    private var healthMonitor: RecordingHealthMonitor?
    private var healthUpdate: (@Sendable (RecordingHealthSnapshot) -> Void)?
    private var healthTimer: DispatchSourceTimer?
    /// The health tick's free-space figure, read on the sampler's own queue at most every ten
    /// seconds, never on `captureQueue` (F877). Thread-safe by itself, so not one of the `_` fields
    /// the capture queue protects.
    private let freeSpace = FreeSpaceSampler()
    private var recordingActivity: NSObjectProtocol?
    private var injectedStopCapture: (() async throws -> Void)?
    private var injectedFinishTracks: (() throws -> Void)?
    private var injectedPreserveTracks: (() -> Void)?
    private var injectedStartCapture: ((
        URL,
        @escaping @Sendable (RecordingHealthSnapshot) -> Void,
        @escaping @Sendable (RecordingMeterSnapshot) -> Void
    ) async throws -> Void)?
    /// Stands in for the restart (F275) so the wiring is testable without a display to lose.
    private var injectedRestartCapture: (@Sendable (Int64) async throws -> Void)?

    /// Where each padded gap sits in this recording's timeline, for the manifest (F282).
    ///
    /// Accumulated here rather than read back from the session sidecar because this is the layer
    /// that does the padding and therefore the only one that knows the frame offset it went in at.
    /// Behind `captureQueue` (F365): appended by the padding on the capture queue and read by
    /// `stop()` from off it, so a raced `Array` could lose or duplicate a span — F282's end state
    /// reached through a race instead of through a lost field.
    private var _paddedGaps: [SourceTrackManifest.PaddedGap] = []
    private var paddedGaps: [SourceTrackManifest.PaddedGap] {
        get { captureQueue.sync { _paddedGaps } }
        set { captureQueue.sync { _paddedGaps = newValue } }
    }

    /// Restarts attempted for the current recording, which `CaptureRestartPolicy` bounds (F275).
    private(set) var restartCount = 0
    /// When each restart in `restartCount` happened, on `ProcessInfo.processInfo.systemUptime`'s
    /// clock — the same clock `CaptureRestartPolicy.action` compares against `now` to bound a
    /// *burst* of restarts rather than a recording's lifetime total (F531).
    private(set) var restartTimestamps: [TimeInterval] = []

    // Fast, throttled level stream that drives the live volume bar, separate from the 1 Hz health
    // snapshot used for warnings.
    private var levelsUpdate: (@Sendable (RecordingMeterSnapshot) -> Void)?
    private var levelMeter = RecordingLevelMeter()
    private var lastLevelsEmittedAt: TimeInterval = 0
    private static let levelsEmitInterval: TimeInterval = 1.0 / 15.0

    override init() {
        super.init()
    }

    init(
        stoppingCapture: @escaping () async throws -> Void,
        finishingTracks: @escaping () throws -> Void,
        // nil runs the real `preservePartialTracks()` body (F632); every other caller replaces it.
        preservingPartialTracks: (() -> Void)?,
        startingCapture: @escaping (
            URL,
            @escaping @Sendable (RecordingHealthSnapshot) -> Void,
            @escaping @Sendable (RecordingMeterSnapshot) -> Void
        ) async throws -> Void,
        restartingCapture: (@Sendable (Int64) async throws -> Void)? = nil,
        directory: URL
    ) {
        injectedStopCapture = stoppingCapture
        injectedFinishTracks = finishingTracks
        injectedPreserveTracks = preservingPartialTracks
        injectedStartCapture = startingCapture
        injectedRestartCapture = restartingCapture
        sessionDirectory = directory
        super.init()
    }

    func start(
        in directory: URL,
        onHealthUpdate: @escaping @Sendable (RecordingHealthSnapshot) -> Void,
        onLevels: @escaping @Sendable (RecordingMeterSnapshot) -> Void
    ) async throws {
        let startBeganAt = ProcessInfo.processInfo.systemUptime
        guard stream == nil, injectedStopCapture == nil else { return }
        if let injectedStartCapture {
            try await injectedStartCapture(directory, onHealthUpdate, onLevels)
            return
        }
        guard await requestMicrophoneAccess() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AudioCaptureError.systemAudioPermissionDenied
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let systemURL = directory.appendingPathComponent("system-audio.f32")
        let microphoneURL = directory.appendingPathComponent("microphone-audio.f32")
        systemWriter = try FloatTrackWriter(
            outputURL: systemURL,
            targetSampleRate: Self.targetSampleRate
        )
        microphoneWriter = try FloatTrackWriter(
            outputURL: microphoneURL,
            targetSampleRate: Self.targetSampleRate
        )

        do {
            let contentRequestBeganAt = ProcessInfo.processInfo.systemUptime
            let stream = try await makeStream()
            let contentReadyAt = ProcessInfo.processInfo.systemUptime
            self.stream = stream
            sessionDirectory = directory
            captureQueue.sync {
                _streamError = nil
                _streamDied = false
            }
            startedAt = Date()
            // Establish the monitor, callbacks, and level fields BEFORE capture begins so the
            // capture queue never reads or writes them concurrently with this setup. No sample
            // buffers are delivered until startCapture() returns.
            healthMonitor = RecordingHealthMonitor(
                startedAt: ProcessInfo.processInfo.systemUptime,
                sampleRate: Self.targetSampleRate
            )
            healthUpdate = onHealthUpdate
            levelsUpdate = onLevels
            levelMeter = RecordingLevelMeter()
            lastLevelsEmittedAt = 0
            // Not inside the bridge (F385): `SCStream.h`'s `startCaptureWithCompletionHandler:`
            // documents its only failure mode as the completion handler's `NSError` — the same
            // channel `startCapture() async throws` already surfaces — and, unlike
            // `AVAudioEngine.h`'s `inputNode`, has no sentence anywhere in the header naming an
            // exception. Verified against the SDK header rather than assumed, per F385's own
            // instruction not to wrap indiscriminately.
            try await stream.startCapture()
            let captureReadyAt = ProcessInfo.processInfo.systemUptime
            Self.logger.info(
                "Recording capture started: shareable-content=\(contentReadyAt - contentRequestBeganAt, format: .fixed(precision: 3))s, stream-start=\(captureReadyAt - contentReadyAt, format: .fixed(precision: 3))s, total=\(captureReadyAt - startBeganAt, format: .fixed(precision: 3))s"
            )
            beginRecordingActivity()
            startHealthTimer()
        } catch {
            Self.logger.error(
                "Recording capture failed after \(ProcessInfo.processInfo.systemUptime - startBeganAt, format: .fixed(precision: 3))s: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)"
            )
            if (systemWriter?.frameCount ?? 0) > 0
                || (microphoneWriter?.frameCount ?? 0) > 0 {
                preservePartialTracks()
            } else {
                discardTrackWriters()
            }
            reset()
            _ = try? InterruptedRecordingRecovery.removeIfEmpty(in: directory)
            throw error
        }
    }

    func stop() async throws -> RecordingArtifact {
        // The writers count too (F292): a restart that failed in `makeStream` leaves `stream == nil`
        // with the tracks still open, and the old guard threw `noAudioCaptured` there without ever
        // reaching `reset()` — leaking the power assertion, the health timer and the dead stream's
        // state into the next recording. The `defer` stays AFTER the guard: a stop that arrives
        // while `start()` is still building the stream must not tear down the writers it just made.
        guard let directory = sessionDirectory,
              stream != nil || systemWriter != nil || microphoneWriter != nil
                || injectedStopCapture != nil else {
            throw AudioCaptureError.noAudioCaptured
        }
        defer { reset() }
        // F292: a capture that already died is finalized from what it wrote, like any other. This
        // used to rethrow the death, which sent Stop down the "recovered after a finishing error"
        // path: a zero-aligned rebuild that drops each track's start offset and never transcribes.
        // That is exactly what the user's 2026-09-18 lid-close test produced. The tracks of a dead
        // capture are not damaged — they simply end early — so the normal mix is the right one.
        var captureHadDied = captureQueue.sync {
            _streamDied || _restartInProgress || (_stream == nil && injectedStopCapture == nil)
        }

        // F809: within `captureSettleBound`. Past it, the capture is finalized from what was written,
        // below, as if the stop had returned: the deferred branch, never a discard. Nothing more
        // lands in the tracks once they are finished on the queue, and the sample handler drops
        // anything from a stream that is no longer `_stream` once `reset()` has run.
        if let stopCall = captureStopCall {
            switch await stopCaptureWithinBound(stopCall) {
            case .stopped:
                break
            case .expired:
                Self.logger.error("Recording stop: the capture did not confirm its stop within the bound; finalizing what was written.")
            case let .failed(error):
                // Stopping a stream ScreenCaptureKit already stopped throws; that is the death we
                // already know about, not a new failure. An injected stop's error is always examined.
                if captureHadDied, injectedStopCapture == nil { break }
                stopHealthTimer()
                await captureQueue.flush()
                // A death delivered between the check above and this stop is still a death, not a
                // finishing failure.
                if streamDied {
                    captureHadDied = true
                } else {
                    preservePartialTracks()
                    throw error
                }
            }
        }
        stopHealthTimer()
        await captureQueue.flush()

        let systemTrack: FloatTrack
        let microphoneTrack: FloatTrack
        do {
            try injectedFinishTracks?()
            let (finishedSystemTrack, finishedMicrophoneTrack) = try captureQueue.sync {
                try finishTrackWriters()
            }
            guard let finishedSystemTrack, let finishedMicrophoneTrack else {
                throw AudioCaptureError.noAudioCaptured
            }
            systemTrack = finishedSystemTrack
            microphoneTrack = finishedMicrophoneTrack
        } catch {
            preservePartialTracks()
            throw error
        }
        guard systemTrack.frameCount > 0 || microphoneTrack.frameCount > 0 else {
            throw AudioCaptureError.noAudioCaptured
        }

        let mixedURL = directory.appendingPathComponent("meeting.wav")
        // `FloatTrackMixer` lives in `WhisperCore` since F278 and throws its own error, so the
        // mapping is explicit here rather than implicit in a shared enum. It keeps the message the
        // user actually sees ("No microphone or system audio was captured.") attached to the layer
        // that owns the wording, instead of leaking a core-level case into a UI alert.
        let duration = try mapMixError {
            try FloatTrackMixer.mix(
                system: systemTrack,
                microphone: microphoneTrack,
                sampleRate: Self.targetSampleRate,
                outputURL: mixedURL
            )
        }
        // F556's measurement, numbers only: how much silence filled skipped spans, and how many
        // frames each track's clock was steered by, over this recording. A long recording with a
        // USB or Bluetooth microphone is what tells whether drift is real and how large.
        let system = systemWriter
        let microphone = microphoneWriter
        // `notice`, not `info`: info lines are kept in memory only, and this one is read back hours
        // later with `log show`.
        Self.logger.notice(
            "Recording track alignment over \(duration, format: .fixed(precision: 1))s: system gap=\(system?.droppedFrames ?? 0) repeated=\(system?.driftRepeatedFrames ?? 0) skipped=\(system?.driftSkippedFrames ?? 0); microphone gap=\(microphone?.droppedFrames ?? 0) repeated=\(microphone?.driftRepeatedFrames ?? 0) skipped=\(microphone?.driftSkippedFrames ?? 0)"
        )
        do {
            try SourceTrackManifest.write(
                system: systemTrack,
                microphone: microphoneTrack,
                sampleRate: Self.targetSampleRate,
                // F282: a padded recording must not describe itself as a clean capture. The spans
                // are written positionally, so a consumer can skip them rather than count inserted
                // silence as recorded non-speech.
                paddedGaps: paddedGaps,
                // F151's separate accounting: many small gaps from dropped buffers, rather than one
                // announced outage. Per track, because the two streams drop independently.
                droppedFrames: (
                    system: systemWriter?.droppedFrames ?? 0,
                    microphone: microphoneWriter?.droppedFrames ?? 0
                ),
                to: directory.appendingPathComponent("source-tracks.json")
            )
        } catch {
            // Best-effort once the mix has succeeded (F502): `meeting.wav` above is already
            // complete and durable — this only describes the raw tracks beside it. Nothing writes
            // it later: `stopRecording` indexes the meeting, and `InterruptedRecordingRecovery`'s
            // backfill (`writeRecoveryManifestIfNeeded`) is reached only for a folder that is not
            // indexed or through a source rebuild, and `SourceRebuild` never offers one over a
            // complete `meeting.wav` (F638). The loss is visible
            // instead — Verify Library reports these tracks as unchecked
            // (`IntegrityFinding.sourceTrackManifestMissing`) rather than reading as clean.
            // Rethrowing here used to send an otherwise-successful Stop down `stopRecording`'s
            // "recovered after a finishing error" path, which drops `healthReport` entirely (a
            // `RecoveredRecording` carries none) and skips automatic transcription — for a
            // recording that lost nothing but a sidecar description of its own raw tracks.
            Self.logger.error(
                "source-tracks.json write failed after meeting.wav was already complete: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)"
            )
        }
        // Capture the health rollup before `reset()` (deferred) nils the monitor.
        var artifact = RecordingArtifact(
            mixedRecordingURL: mixedURL,
            systemTrackURL: systemTrack.url,
            microphoneTrackURL: microphoneTrack.url,
            duration: duration,
            healthReport: healthMonitor?.report()
        )
        artifact.captureStoppedEarly = captureHadDied
        artifact.capturedAlignment = SourceTrackManifest.capturedAlignment(
            system: systemTrack,
            microphone: microphoneTrack,
            paddedGaps: paddedGaps,
            droppedFrames: (
                system: systemWriter?.droppedFrames ?? 0,
                microphone: microphoneWriter?.droppedFrames ?? 0
            )
        )
        return artifact
    }

    func cancel() async {
        if let stopCall = captureStopCall {
            // F809: within the same bound as Stop's, since a Cancel that never got past this held
            // every quit just the same (F672 waits for `.stopping`). A discard has nothing to save,
            // so a stop that never confirms is simply let go; its failure was ignored before too.
            // F929: the same call Stop makes, the injected stop included, so a Cancel whose stop
            // never returns can be driven rather than only pinned as source.
            _ = await stopCaptureWithinBound(stopCall)
        }
        stopHealthTimer()
        await captureQueue.flush()
        discardTrackWriters()
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        reset()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard stream === _stream else { return }
        // F809: only the live stream's buffers belong to this recording. Stop lets go of a stream
        // whose `stopCapture()` did not return within its bound, and if that stream is still
        // delivering, its buffers would land in whatever writers are current, which can be the next
        // recording's. `start()` and a restart publish a stream before starting it, so the live one
        // always passes. On the capture queue (both `addStreamOutput` calls name it), so `_stream`.
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        // Which track a failure below belongs to (F876): the health monitor counts each track's
        // consecutive failures on its own. Only `.audio` and `.microphone` outputs are added
        // (`makeStream`), so nil never meets a write.
        let track: RecordingChannel? = switch outputType {
        case .audio: .systemAudio
        case .microphone: .microphone
        default: nil
        }
        do {
            // F292: a restarted capture's first buffer must land AFTER the silence for the gap.
            try applyPendingRestartPaddingIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            switch outputType {
            case .audio:
                if let level = try _systemWriter?.append(sampleBuffer) {
                    healthMonitor?.recordWriteOutcome(.systemAudio, succeeded: true)
                    healthMonitor?.receive(.systemAudio, level: level, at: now)
                    levelMeter.receive(.systemAudio, level: level, at: now)
                    emitLevelsIfNeeded(at: now)
                }
            case .microphone:
                if let level = try _microphoneWriter?.append(sampleBuffer) {
                    healthMonitor?.recordWriteOutcome(.microphone, succeeded: true)
                    healthMonitor?.receive(.microphone, level: level, at: now)
                    levelMeter.receive(.microphone, level: level, at: now)
                    emitLevelsIfNeeded(at: now)
                }
            case .screen:
                break
            @unknown default:
                break
            }
        } catch {
            // Already on `captureQueue` — both of `makeStream`'s `addStreamOutput` calls install
            // the sample handler with it as its `sampleHandlerQueue`, so the stored property, not
            // the accessor (F364).
            _streamError = error
            // F386. Since F363 stopped a failed write tearing the stream down, a persistent
            // failure drops every buffer while the recording looks alive: the HUD counts, the
            // level meter moves, and nothing lands. `_streamError` alone does not surface —
            // three consecutive failures on one track raise an at-risk warning, which the risk
            // announcer and the menu-bar title already carry. Counted per track (F876), so the
            // other track landing does not hide this one failing. With its cause (F888), so the
            // warning tells someone to check disk space only when the disk may be what failed.
            if let track {
                healthMonitor?.recordWriteOutcome(track, succeeded: false, cause: Self.writeFailureCause(of: error))
            }
        }
    }

    /// Which advice a failed append earns (F888).
    ///
    /// `FloatTrackWriter.append` throws `AudioCaptureError.conversionFailed` from every step before
    /// its write (the format description, the buffer list, the PCM buffer, the downmix, the
    /// converter) and nothing else. The write itself, and the restart padding before it, throw the
    /// file system's own error, which `FloatTrackFile.append` passes on unchanged. So a conversion
    /// failure is the captured audio's format, and anything else is storage, which keeps the disk
    /// advice whenever the cause is unclear.
    static func writeFailureCause(of error: Error) -> RecordingWriteFailureCause {
        if case AudioCaptureError.conversionFailed = error { return .format }
        return .storage
    }

    /// Emits combined levels no more often than `levelsEmitInterval` so the volume bar updates
    /// smoothly without flooding the main actor.
    private func emitLevelsIfNeeded(at time: TimeInterval, force: Bool = false) {
        guard let levelsUpdate else { return }
        guard force || time - lastLevelsEmittedAt >= Self.levelsEmitInterval else { return }
        lastLevelsEmittedAt = time
        levelsUpdate(levelMeter.snapshot(at: time))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordStreamStop(from: stream, error: error)
    }

    /// The delegate's body, extracted so a test can reach its identity guard (F484).
    ///
    /// Only the live stream's stop is a death. After a restart the replaced stream can still report
    /// its own stop, late; without the check that report would mark the healthy new capture dead and
    /// the health tick would restart it again. `StreamStopIdentityTests` drives both sides, and
    /// checks that the delegate above is nothing but this forward.
    func recordStreamStop(from candidate: AnyObject, error: Error) {
        captureQueue.async { [weak self] in
            // Already on the capture queue: the `_` storage, read through the computed
            // `_liveStreamIdentity`, not the syncing `stream` accessor (F334).
            guard let self, self._liveStreamIdentity === candidate else { return }
            self.recordStreamDeath(error)
        }
    }

    /// The object a stop report must be to count as the live stream: `_stream`, or in a DEBUG
    /// build a stand-in a test installed (F484). No test puts a real stream in `_stream`. One could
    /// be built: `SCStream`'s own `init` is unavailable but `SCContentFilter`'s is not, so
    /// `SCStream(filter: SCContentFilter(), …)` typechecks. But ScreenCaptureKit's headers do not say
    /// whether constructing a stream asks for the Screen Recording permission, and a test must never
    /// risk that prompt. `liveStreamIdentityIsTheStreamOutsideDebug` pins, as source, that outside
    /// DEBUG this is `_stream` and nothing else. Must run on `captureQueue`.
    private var _liveStreamIdentity: AnyObject? {
        #if DEBUG
        if let _liveStreamStandInForTesting { return _liveStreamStandInForTesting }
        #endif
        return _stream
    }

    #if DEBUG
    /// Records a capture-stream failure without the delegate's identity guard. No production code
    /// calls it; it is internal so `StreamFailurePowerAssertionTests` and the other death tests can
    /// drive it without an `SCStream` (F254). The delegate's own path is `recordStreamStop` (F484).
    /// DEBUG-only since F726: an unguarded way to mark the live capture dead has no business in the
    /// shipped app, and `recordStreamStop` is the one door a release build has.
    ///
    /// It deliberately does **not** end the recording activity, which is what it used to do. That
    /// single line put the Mac to sleep five seconds after a lid close, twice, on the user's own
    /// machine — confirmed from `pmset -g log`:
    ///
    ///     15:37:46  Display is turned off
    ///     15:37:46  Released PreventUserIdleSystemSleep "Recording meeting audio" (held 01:03:01)
    ///     15:37:51  Entering Sleep state due to 'Clamshell Sleep'
    ///
    /// The stream is bound to one display (the `SCContentFilter(display:…)` built in `makeStream()`),
    /// so closing the lid kills it; releasing the assertion in response removed the only thing
    /// keeping the machine awake, before a single byte had been finalized. The assertion is still
    /// released in `reset()`, which runs on stop and cancel — once the recording has actually been
    /// dealt with.
    ///
    /// The cost of holding it: if the stream dies and the user never stops the recording, the Mac
    /// will not idle-sleep. That is the right side to err on — a battery cost against losing the
    /// rest of a meeting — and it goes away once something finalizes automatically on stream death
    /// (F253). `RecordingHealthMonitor` already surfaces the dead stream within ~4 s.
    func handleStreamFailure(_ error: Error) {
        captureQueue.sync { recordStreamDeath(error) }
    }
    #endif

    /// The body of `handleStreamFailure`, for callers already on `captureQueue`.
    ///
    /// F364 split these apart rather than making one function guess. The delegate reaches this from
    /// inside a `captureQueue.async`, where the syncing accessors would deadlock; the tests reach
    /// the DEBUG-only `handleStreamFailure` (F726) from off the queue, where the stored properties
    /// would race. Both are real callers, so both need their own door.
    private func recordStreamDeath(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        _streamError = error
        _streamDied = true
    }

    /// Finishes both track writers, returning whatever each produced. Must run on `captureQueue`
    /// (F388): it reaches the stored `_systemWriter`/`_microphoneWriter` directly, the same objects
    /// `applyPendingRestartPaddingIfNeeded` calls `appendSilence` on from the capture queue. Before
    /// this, `stop()` read the writers through the syncing `systemWriter`/`microphoneWriter`
    /// accessors — which protect only the load of the reference — and then called `finish()`
    /// itself OFF the queue, safe today only because the session-generation guard happens to keep
    /// a restart from ever landing in the same window. That guarantee belongs to a different
    /// mechanism than the queue, so a future caller that does not know about it could reopen this
    /// silently; the precondition below traps loudly instead the moment that stops being true.
    private func finishTrackWriters() throws -> (FloatTrack?, FloatTrack?) {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        let system = try _systemWriter?.finish()
        let microphone = try _microphoneWriter?.finish()
        return (system, microphone)
    }

    /// Whether the capture currently holds its `beginActivity` power assertion (F254).
    var isHoldingRecordingActivity: Bool { recordingActivity != nil }

    /// Runs a `FloatTrackMixer` call, translating its error into this layer's (F278).
    ///
    /// The mixer moved to `WhisperCore` and cannot depend on `AudioCaptureError`, which carries the
    /// user-facing wording. One case, translated in one place, rather than a core module reaching up
    /// for a UI string.
    private func mapMixError<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch FloatTrackMixError.noAudioCaptured {
            throw AudioCaptureError.noAudioCaptured
        }
    }

    /// Builds a configured `SCStream` around the main display, pinned per F254.
    ///
    /// Extracted by F275 so `start` and `restartAfterFailure` build the capture the same way. The
    /// pinning is the point: the stream dies with the display it is filtered on, and in clamshell
    /// the built-in one is what goes away — so this is the difference between a docked Mac keeping
    /// its capture and losing it. It does not save an undocked lid close; nothing can, because the
    /// machine sleeps. See F254 for the `pmset` chain.
    ///
    /// Re-querying `SCShareableContent` on every build is what makes the restart work at all: after
    /// a display disappears, the previous filter names a display that no longer exists.
    private func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let index = Self.preferredDisplayIndex(
            displayIDs: content.displays.map(\.displayID),
            mainDisplayID: CGMainDisplayID()
        ) else {
            throw AudioCaptureError.noDisplayAvailable
        }
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: content.displays[index],
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(Self.targetSampleRate)
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        return stream
    }

    /// Brings the capture back up and pads the gap with silence (F275, reworked by F292).
    ///
    /// The padding goes into both tracks, because that is the whole difference between this and a
    /// splice: without it the samples after the gap sit at the wrong offset and every later
    /// timestamp is wrong by the gap's duration — wrong *invisibly*, since the file plays and the
    /// numbers are self-consistent. That is F151, and reintroducing it deliberately would be worse
    /// than losing the segment, because the user cannot detect it.
    ///
    /// **Written only once the new stream is running** (F292). It used to go in first, so a
    /// restart that then failed left silence on disk that neither the sidecar nor the manifest
    /// recorded — and now that a failed restart is retried rather than ending the meeting, every
    /// retry would have padded the same outage again. Instead the silence is *owed*: set before
    /// `startCapture`, paid on the capture queue before the first new buffer is written (or right
    /// after `startCapture` returns, whichever comes first), and cancelled if the start fails.
    ///
    /// Writing silence here is not the fabrication F256 refuses: nothing was captured while the
    /// display was gone, so silence is the truth about that interval rather than an invention about
    /// audio that existed.
    func restartAfterFailure(paddingFrames: Int64) async throws {
        // The death is cleared BEFORE the new stream can start, so a new stream that dies at once
        // records its own death rather than having it erased by a clear that runs after it. Put
        // back if the restart fails, which keeps `captureDidDie` true for the retry.
        let (generation, previousError) = captureQueue.sync { () -> (Int, Error?) in
            let previous = _streamError
            _restartInProgress = true
            _streamError = nil
            _streamDied = false
            return (_sessionGeneration, previous)
        }
        defer {
            captureQueue.sync { if generation == _sessionGeneration { _restartInProgress = false } }
        }
        var startedStream: SCStream?
        do {
            if let injectedRestartCapture {
                // The injected seam stands in for building and starting the stream only; the owing,
                // paying and cancelling of the padding below is the real logic, so tests drive it.
                setPendingRestartPadding(paddingFrames)
                try await injectedRestartCapture(paddingFrames)
                try ensureSession(generation)
            } else {
                // Tear down whatever is left of the dead stream before building another.
                // `stopCapture` on an already-dead stream throws, which is expected here.
                if let stream {
                    try? await stream.stopCapture()
                    try ensureSession(generation)
                    self.stream = nil
                }
                let stream = try await makeStream()
                try publishRestart(stream, generation: generation, paddingFrames: paddingFrames)
                // Not inside the bridge (F385) — see the reasoning at `start()`'s own call.
                try await stream.startCapture()
                startedStream = stream
                try ensureSession(generation)
            }
            // The check and the padding in ONE step on the queue (F365). `ensureSession` on the
            // line before is a check-then-act: a stop landing between it and this `sync` would
            // pay silence into writers `stop()` is already finishing, and `FloatTrackFile.finish`'s
            // doc says what that costs — the descriptor may already have been reused by another
            // open file, so the write lands in an unrelated one.
            try captureQueue.sync {
                guard generation == _sessionGeneration else { throw CancellationError() }
                try applyPendingRestartPaddingIfNeeded()
            }
        } catch {
            // A stream this restart started is stopped again whatever went wrong after it started:
            // left running, it would capture into writers that are about to be dropped.
            if let startedStream { try? await startedStream.stopCapture() }
            // Only this recording's state is put back. If a stop or cancel reset the engine while
            // the restart was waiting, the state belongs to nobody — or to the next recording.
            captureQueue.sync {
                guard generation == _sessionGeneration else { return }
                if startedStream != nil || injectedRestartCapture == nil { _stream = nil }
                _pendingRestartPadding = 0
                _streamError = _streamError ?? previousError ?? error
                _streamDied = true
            }
            if !(error is CancellationError) {
                Self.logger.error(
                    "Recording capture restart failed: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)"
                )
            }
            throw error
        }
        // Counted only when it worked (F292). The bound exists for a capture that keeps dying after
        // it comes back; a restart that cannot even start is bounded by the padding cap instead,
        // with a backoff between attempts, so a display that is gone for good still ends in a save.
        restartCount += 1
        restartTimestamps.append(ProcessInfo.processInfo.systemUptime)
        Self.logger.info(
            "Recording capture restarted after \(paddingFrames) padded frames (restart \(self.restartCount))"
        )
    }

    /// Invalidates an in-flight restart so a stop can finalize without racing it (F365).
    ///
    /// Stop's bounded wait used to be a fall-through: `waitForCaptureRestartToSettle` returned
    /// nothing and the caller proceeded either way, so a restart that outlived the 10 s bound ran
    /// in parallel with `stop()`'s finalize. `restartAfterFailure` exceeds 10 s easily — it awaits
    /// `SCShareableContent.excludingDesktopWindows`, the call this file logs separately because it
    /// is slow, and slowest exactly when displays are in flux.
    ///
    /// Bumping the generation is what the counter is for: the restart's next `ensureSession`
    /// throws `CancellationError`, its catch stops any stream it started, and its state-restoring
    /// `sync` sees a generation that is no longer its own and touches nothing.
    ///
    /// `_restartInProgress` is deliberately left set. `stop()` reads it to decide `captureHadDied`,
    /// and a capture whose restart was abandoned did die; clearing it here would send Stop down the
    /// "finishing failure" path instead of the normal finalize.
    ///
    /// Returns whether there was a restart to abandon, so the caller can say so rather than guess.
    @discardableResult
    func abandonInFlightRestart() -> Bool {
        let abandoned: Bool = captureQueue.sync {
            guard _restartInProgress else { return false }
            _sessionGeneration += 1
            // Nothing is owed any more: the restart that owed it is cancelled, and paying it would
            // put silence into a timeline that never had a gap paid for it.
            _pendingRestartPadding = 0
            return true
        }
        // Logged either way. "The wait ran out and there was nothing in flight" is a different
        // fact from "the wait ran out and a restart was killed", and the first one means the
        // bound is mistuned rather than that a restart hung.
        if abandoned {
            Self.logger.error("Stop's restart wait ran out; the in-flight capture restart was cancelled.")
        } else {
            Self.logger.info("Stop's restart wait ran out, but no restart was in flight.")
        }
        return abandoned
    }

    /// A stream's stop, as a value a task can carry (F809). Unchecked because the injected seam's
    /// closure and `SCStream` are not `Sendable`; the call runs exactly once, in one task.
    private struct CaptureStopCall: @unchecked Sendable {
        let run: () async throws -> Void
    }

    /// The stop that `stop()` and `cancel()` wait on: the injected one when a test supplied it,
    /// otherwise the live stream's `stopCapture()`, otherwise none. One choice for both (F929):
    /// `cancel()` used to look only at the stream, so its bound could not be driven by a test.
    private var captureStopCall: CaptureStopCall? {
        if let injectedStopCapture { return CaptureStopCall(run: injectedStopCapture) }
        if let stream { return CaptureStopCall { try await stream.stopCapture() } }
        return nil
    }

    /// What became of a `stopCapture()` that Stop waited on within `captureSettleBound` (F809).
    private enum CaptureStopOutcome: Sendable {
        case stopped
        case failed(any Error)
        /// The bound ran out first. The call is still running, and nothing waits for it any more.
        case expired
    }

    /// Runs a stream's stop, but answers `.expired` once `captureSettleBound` passes without it
    /// (F809).
    ///
    /// `SCStream.stopCapture()` has no bound of its own, and a stop that never returned used to hold
    /// Stop at "Finishing…" and, since F672, every quit, until Force Quit. Only the first outcome is
    /// answered: a call that returns or throws after the bound changes nothing, because Stop has
    /// already finalized the tracks and reset the engine. Its stream is no longer `_stream`, so the
    /// sample handler drops anything it still delivers.
    ///
    /// Every answer is logged with how long it took (F930), `stream-stop=<ms>ms`, because
    /// `captureSettleBound` is a reused choice that nothing measured. A call that returns after the
    /// bound has already been answered logs a second time, `confirmed=late`, with its real duration:
    /// that line is the evidence for tuning the bound, and the only way to get it.
    private func stopCaptureWithinBound(_ call: CaptureStopCall) async -> CaptureStopOutcome {
        let deadline = stopCaptureDeadline
        let record = stopTimingRecorder
        let began = ProcessInfo.processInfo.systemUptime
        let elapsed: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime - began }
        return await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            // Returns whether this was the first answer, the one Stop or Cancel acts on.
            let answer: @Sendable (CaptureStopOutcome) -> Bool = { outcome in
                let first = answered.withLock { done in
                    let first = !done
                    done = true
                    return first
                }
                if first {
                    record(Self.stopTimingLine(elapsed: elapsed(), outcome: outcome, late: false))
                    continuation.resume(returning: outcome)
                }
                return first
            }
            let expiry = Task {
                await deadline()
                if !Task.isCancelled { _ = answer(.expired) }
            }
            Task {
                let outcome: CaptureStopOutcome
                do {
                    try await call.run()
                    outcome = .stopped
                } catch {
                    outcome = .failed(error)
                }
                if !answer(outcome) {
                    record(Self.stopTimingLine(elapsed: elapsed(), outcome: outcome, late: true))
                }
                expiry.cancel()
            }
        }
    }

    /// The `stream-stop=` line for one answer (F930): `confirmed=yes` for a stop that returned within
    /// the bound, `no` for one that threw or that the bound ran out on, and `late` for a call that
    /// returned, either way, after the bound had been answered. Milliseconds, `saturating:` because
    /// a `Double` conversion that overflows traps (AGENTS.md).
    private static func stopTimingLine(elapsed: TimeInterval, outcome: CaptureStopOutcome, late: Bool) -> String {
        let milliseconds = Int(saturating: (max(0, elapsed) * 1_000).rounded())
        let (confirmed, name): (String, String) = switch outcome {
        case .stopped: (late ? "late" : "yes", "stopped")
        case .failed: (late ? "late" : "no", "failed")
        case .expired: ("no", "expired")
        }
        return "stream-stop=\(milliseconds)ms confirmed=\(confirmed) outcome=\(name)"
    }

    /// Where `stream-stop=` lines go: the log, and in a DEBUG build a test's probe (F930). Read once
    /// per stop, before the call starts, so the closures above carry no reference to the engine.
    private var stopTimingRecorder: @Sendable (String) -> Void {
        #if DEBUG
        let probe = stopTimingLinesForTesting
        #endif
        return { line in
            Self.logger.notice("Recording capture stop: \(line, privacy: .public)")
            #if DEBUG
            probe?(line)
            #endif
        }
    }

    /// Stop's deadline for `stopCapture()`: sleeping out `captureSettleBound`, or a test's (F809).
    private var stopCaptureDeadline: @Sendable () async -> Void {
        #if DEBUG
        if let stopCaptureDeadlineForTesting { return stopCaptureDeadlineForTesting }
        #endif
        return { try? await Task.sleep(for: AudioCaptureEngine.captureSettleBound) }
    }

    /// Throws `CancellationError` when a stop or cancel has reset the engine since `generation`.
    private func ensureSession(_ generation: Int) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    /// Hands the restarted stream over to the engine — the check and both assignments in **one**
    /// step on the capture queue (F334).
    ///
    /// Separately they were a check-then-act: a `reset()` landing between "is this session still
    /// mine?" and the assignment left `stream` non-nil and silence owed on an engine that had been
    /// reset, and the catch below deliberately restores nothing in that case. `start()` is
    /// `guard stream == nil`, so the next meeting then recorded nothing at all — the precise
    /// failure the generation counter exists to prevent. Stop's bounded wait
    /// (`waitForCaptureRestartToSettle`, 10 s) running out is what puts the two in parallel.
    private func publishRestart(_ stream: SCStream?, generation: Int, paddingFrames: Int64) throws {
        try captureQueue.sync {
            guard generation == _sessionGeneration else { throw CancellationError() }
            #if DEBUG
            onRestartPublishWindowForTesting?()
            #endif
            _pendingRestartPadding = max(0, paddingFrames)
            if let stream { _stream = stream }
        }
    }

    #if DEBUG
    /// Test seams for F334: the window between "is this session still mine?" and publishing the
    /// restarted stream is where a racing `reset()` used to land. Nothing in the app sets these.
    var onRestartPublishWindowForTesting: (@Sendable () -> Void)?

    /// Test seam (F809): returns when Stop's wait for `stopCapture()` runs out, in place of
    /// sleeping out `captureSettleBound`. Nothing in the app sets it.
    var stopCaptureDeadlineForTesting: (@Sendable () async -> Void)?

    /// Test seam (F930): told each `stream-stop=` line the logger gets. Nothing in the app sets it.
    var stopTimingLinesForTesting: (@Sendable (String) -> Void)?

    var sessionGenerationForTesting: Int { sessionGeneration }
    var pendingRestartPaddingForTesting: Int64 { captureQueue.sync { _pendingRestartPadding } }
    var hasLiveStreamForTesting: Bool { stream != nil }

    func publishRestartForTesting(generation: Int, paddingFrames: Int64) throws {
        try publishRestart(nil, generation: generation, paddingFrames: paddingFrames)
    }

    /// F484: what `recordStreamStop` treats as the live stream in place of `_stream`, which no test
    /// fills (`_liveStreamIdentity` says why). Nothing in the app sets it, and `reset()` does not
    /// clear it.
    private var _liveStreamStandInForTesting: AnyObject?

    func installLiveStreamStandInForTesting(_ standIn: AnyObject?) {
        captureQueue.sync { _liveStreamStandInForTesting = standIn }
    }

    /// Returns once every block already queued on `captureQueue` has run (F484). `recordStreamStop`
    /// hands its work to the queue asynchronously, so a test drains the queue before it asserts,
    /// rather than counting on the accessor it reads next happening to wait on the same queue.
    func drainCaptureQueueForTesting() {
        captureQueue.sync {}
    }

    /// What a stop or a cancel does to the session state, without the stream teardown around it.
    func resetForTesting() { reset() }

    /// Occupies `captureQueue` the way one long block of restart padding does (F401): signals
    /// `entered` once the block is running, then holds the queue until `release` is signalled.
    func holdCaptureQueueForTesting(entered: DispatchSemaphore, release: DispatchSemaphore) {
        captureQueue.async {
            entered.signal()
            release.wait()
        }
    }
    #endif

    /// Silence owed to both tracks by a restart in progress (F292). Read and written only on the
    /// capture queue, which is also where the sample handler runs, so it is paid exactly once.
    /// `_`-prefixed since F402, like the rest of the queue's storage, so the derived guard in
    /// `CaptureQueueProtectionGuardTests` checks every use of it.
    private var _pendingRestartPadding: Int64 = 0

    func setPendingRestartPadding(_ frames: Int64) {
        captureQueue.sync { _pendingRestartPadding = max(0, frames) }
    }

    /// Pays owed restart silence into both tracks and records where it went (F282). Must run on
    /// the capture queue, and traps if it does not (F402): it writes through the stored writers and
    /// appends to `_paddedGaps`. Its two callers are the sample handler and the restart's own
    /// `captureQueue.sync`.
    func applyPendingRestartPaddingIfNeeded() throws {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        guard _pendingRestartPadding > 0 else { return }
        let frames = _pendingRestartPadding
        _pendingRestartPadding = 0
        // A writer with no first buffer yet has nothing to align this padding against (F460): the
        // MIXER's own front-padding positions a track from `firstPresentationTime` once its real
        // audio starts, so writing silence ahead of that would double the gap AND anchor it at
        // frame 0 of a track that had not started — `CaptureGapPolicy` never sees it as padding
        // either, because the writer's `firstPresentationTime` is set to that first REAL buffer's
        // own timestamp, making the offset it compares against exactly 0.
        let systemStarted = _systemWriter?.firstPresentationTime != nil
        let microphoneStarted = _microphoneWriter?.firstPresentationTime != nil
        guard systemStarted || microphoneStarted else { return }
        // Recorded before the padding goes in, so `startSeconds` is where the gap begins — on
        // whichever writer is actually being padded, since that is the track this span sits on.
        // Both started writers stay frame-aligned by every earlier restart, so either answers the
        // same question when both qualify.
        let framesBeforePadding = (systemStarted ? _systemWriter : _microphoneWriter)?.frameCount ?? 0
        if systemStarted { try _systemWriter?.appendSilence(frames: frames) }
        if microphoneStarted { try _microphoneWriter?.appendSilence(frames: frames) }
        _paddedGaps.append(
            SourceTrackManifest.PaddedGap(
                startSeconds: Double(framesBeforePadding) / Self.targetSampleRate,
                durationSeconds: Double(frames) / Self.targetSampleRate
            )
        )
    }

    /// Which display the content filter should be pinned to, as an index into `displayIDs` (F254).
    ///
    /// The filter is built around exactly ONE display, and this used to be `displays.first` —
    /// which is not documented to be the main display, so the display a capture depended on was
    /// arbitrary. That matters because the display going away kills the stream: confirmed twice on
    /// the user's machine, where a lid close took the capture with it. In clamshell the built-in
    /// display is the one that disappears, so pinning to the main display is what gives a docked Mac
    /// any chance of surviving a lid close.
    ///
    /// Falls back to the first display rather than nil when the main one is not in the list, because
    /// an arbitrary display still records and `noDisplayAvailable` aborts the capture outright.
    /// Pure and index-based so the rule is testable without an `SCDisplay`, which cannot be built.
    static func preferredDisplayIndex(
        displayIDs: [CGDirectDisplayID],
        mainDisplayID: CGDirectDisplayID
    ) -> Int? {
        guard !displayIDs.isEmpty else { return nil }
        return displayIDs.firstIndex(of: mainDisplayID) ?? 0
    }

    #if DEBUG
    /// Test seam (F292): real track writers without a capture, so `stop()`'s finalize can be driven
    /// the way a dead capture leaves it.
    /// `deviceSync` reaches each track's `FloatTrackFile`, so a test can observe where `finish()`'s
    /// flush runs (F632). `systemFinishFailure` makes the system track's `finish()` throw once,
    /// after the track is finalized, so a test can check that one track's failure does not skip
    /// the other's finish (F632). `onTrackCancel` is told each track's URL when it is discarded,
    /// so a test can observe where `cancel()` runs (F734).
    func beginTestTrackSession(
        in directory: URL,
        deviceSync: @escaping FloatTrackFile.DeviceSync = FloatTrackFile.fullFsync,
        systemFinishFailure: Error? = nil,
        onTrackCancel: ((URL) -> Void)? = nil
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let system = try FloatTrackWriter(
            outputURL: directory.appendingPathComponent("system-audio.f32"), targetSampleRate: Self.targetSampleRate,
            deviceSync: deviceSync
        )
        system.finishFailureForTesting = systemFinishFailure
        system.cancelProbeForTesting = onTrackCancel
        systemWriter = system
        let microphone = try FloatTrackWriter(
            outputURL: directory.appendingPathComponent("microphone-audio.f32"), targetSampleRate: Self.targetSampleRate,
            deviceSync: deviceSync
        )
        microphone.cancelProbeForTesting = onTrackCancel
        microphoneWriter = microphone
        sessionDirectory = directory
        healthMonitor = RecordingHealthMonitor(
            startedAt: ProcessInfo.processInfo.systemUptime,
            sampleRate: Self.targetSampleRate
        )
    }

    func writeTestFrames(system: Int64, microphone: Int64, systemStart: Double, microphoneStart: Double) throws {
        try systemWriter?.appendTestFrames(system, firstPresentationTime: systemStart)
        try microphoneWriter?.appendTestFrames(microphone, firstPresentationTime: microphoneStart)
    }

    /// Writes frames to only the microphone writer, leaving the system writer completely
    /// untouched — so its `firstPresentationTime` stays nil, standing in for "no system audio has
    /// been detected yet" (F460). `writeTestFrames` above cannot express this: it calls
    /// `appendTestFrames` on both writers unconditionally, which sets `firstPresentationTime` even
    /// at frame count 0.
    func writeTestFrames(microphoneOnly frames: Int64, firstPresentationTime start: Double) throws {
        try microphoneWriter?.appendTestFrames(frames, firstPresentationTime: start)
    }

    /// A buffer that failed to convert or write while the stream kept running — `streamError`
    /// without a death, which the sample handler's catch produces.
    func recordWriteFailureForTesting(_ error: Error) {
        streamError = error   // the syncing accessor: tests call this from off the queue
    }

    /// Whether any capture failure has been recorded: a death, or one buffer that failed to convert
    /// or write. Test-only, so F402 moved it under DEBUG. No production code reads it: `stop()`
    /// reads `_streamDied` itself, the restart decision reads it through `captureDidDie`, and only a
    /// death sets it.
    var hasStreamError: Bool { captureQueue.sync { _streamError != nil } }

    var testFrameCounts: (system: Int64, microphone: Int64) {
        (systemWriter?.frameCount ?? 0, microphoneWriter?.frameCount ?? 0)
    }
    #endif

    /// Whether the capture stream itself died, as opposed to a buffer failing to convert or write.
    ///
    /// F363: the restart decision used to read `hasStreamError`, which cannot tell the two apart, so
    /// a single throwing write — a full disk is the realistic cause — tore down a stream that was
    /// still delivering, padded the timeline with silence for audio that had been captured, recorded
    /// the fabricated outage in the manifest, and ended the meeting after three cycles telling the
    /// user the capture "stopped unexpectedly". `_streamDied` is set true only by
    /// `recordStreamDeath` — reached from `stream(_:didStopWithError:)`, and from the DEBUG-only
    /// `handleStreamFailure` (F726) — and by the restart's own failure path, which puts back the death the
    /// restart had cleared. So it means a death and nothing else (F402 corrected who sets it).
    ///
    /// Read from `streamDiedMirror`, not through `captureQueue.sync` (F401). The 1 Hz health tick
    /// and `handleCaptureInterruption` call this from the MainActor, and a sync read waited behind
    /// any restart padding in flight. This is safe from any thread, including `captureQueue`
    /// itself. Code that must act on the value in the same step as other queue state reads
    /// `_streamDied` inside its own queue block instead.
    var captureDidDie: Bool { streamDiedMirror.withLock { $0 } }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func reset() {
        stopHealthTimer()
        endRecordingActivity()
        // Every field a restart on another thread can be reading, in one step, so the restart sees
        // either the whole reset or none of it (F334).
        captureQueue.sync {
            _stream = nil
            _streamError = nil
            _streamDied = false
            _restartInProgress = false
            _sessionGeneration += 1
            _pendingRestartPadding = 0
            // F365: inside, where this block's own comment always said they belonged. Nilling a
            // writer outside the sync is the over-release the accessors exist to prevent, and it
            // raced `applyPendingRestartPaddingIfNeeded` on the capture queue.
            _systemWriter = nil
            _microphoneWriter = nil
            _paddedGaps = []
        }
        sessionDirectory = nil
        startedAt = nil
        healthMonitor = nil
        healthUpdate = nil
        levelsUpdate = nil
        injectedStopCapture = nil
        injectedFinishTracks = nil
        injectedPreserveTracks = nil
        // Per recording, not per app run (F275): the policy's bound is "this meeting may restart N
        // times [within a burst]", so carrying the count (or the timestamps behind it) into the next
        // recording would make a Mac that lost one capture refuse to retry the following one.
        restartCount = 0
        restartTimestamps = []
        levelMeter = RecordingLevelMeter()
        lastLevelsEmittedAt = 0
    }

    /// Finalizes whatever the tracks hold on an abort route. On `captureQueue` since F632, for
    /// F388's reason: `finish()` closes the descriptor that the sample handler and the restart
    /// padding write through on that queue. Every caller is in `start()`/`stop()`, never on the
    /// queue, so the `sync` cannot deadlock.
    private func preservePartialTracks() {
        if let injectedPreserveTracks {
            injectedPreserveTracks()
        } else {
            captureQueue.sync { finishTrackWritersBestEffort() }
        }
    }

    /// `finishTrackWriters()`'s abort-path twin (F632). Not a `try?` around that function: it
    /// finishes the two writers in sequence, so a system finish that threw would skip the
    /// microphone's — and saving what there is means trying each track on its own.
    private func finishTrackWritersBestEffort() {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        _ = try? _systemWriter?.finish()
        _ = try? _microphoneWriter?.finish()
    }

    /// Discards both tracks, for a capture that never became a recording: `cancel()`, and `start()`'s
    /// catch when nothing was written. On `captureQueue` since F734, for F632's reason on the discard
    /// path: `FloatTrackFile.cancel` marks the track finished, closes its descriptor and removes the
    /// file, and the sample handler and the restart padding write through that descriptor on the
    /// queue. Reached through the syncing accessors, only the load of the reference was protected,
    /// and `cancel()` ignores a `stopCapture()` that failed, so a stream that would not stop could
    /// still be appending. Neither caller is on the queue, so the `sync` cannot deadlock.
    private func discardTrackWriters() {
        captureQueue.sync {
            _systemWriter?.cancel()
            _microphoneWriter?.cancel()
        }
    }

    /// Internal rather than private so F254's tests can drive the assertion's lifetime directly;
    /// an injected capture returns before `start()` reaches this, so there is no other way in.
    ///
    /// Note `.idleSystemSleepDisabled` does not cover what actually bit the user: it suppresses
    /// *idle* sleep, not a lid close, and not display sleep — and the log shows the display turning
    /// off is what killed the stream in the first place (F254).
    func beginRecordingActivity() {
        // Idempotent: a second begin would otherwise strand the first assertion with no handle to
        // release it, and nothing would ever let the Mac sleep again.
        guard recordingActivity == nil else { return }
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Recording meeting audio"
        )
    }

    func endRecordingActivity() {
        guard let recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(recordingActivity)
        self.recordingActivity = nil
    }

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: Self.healthTickInterval)
        timer.setEventHandler { [weak self] in
            self?.emitHealthSnapshot()
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func emitHealthSnapshot() {
        guard let healthMonitor, let healthUpdate else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Force a low-frequency meter snapshot as a fallback so stale levels decay even if both
        // capture channels stop producing buffers entirely.
        emitLevelsIfNeeded(at: now, force: true)
        // Not read here (F877): `availableStorageBytes` is an uncached query of 7–50 ms, and this
        // runs on `captureQueue`. The sampler hands back its latest figure and reads elsewhere.
        let availableBytes = sessionDirectory.flatMap { freeSpace.latest(for: $0, at: now) }
        healthUpdate(healthMonitor.snapshot(
            at: now,
            availableStorageBytes: availableBytes
        ))
    }

    /// Free space on the volume holding `directory`, read from the file system on every call (F703).
    ///
    /// The tick hands this the same `sessionDirectory` for the whole recording, and a `URL` answers
    /// `resourceValues(forKeys:)` from its own cache when it can (`NSURL.h:181`). That cache clears by
    /// itself only for a URL used from the main thread, "the next time the main thread's run loop
    /// runs" (`NSURL.h:172`); `captureQueue` is a dispatch queue with no run loop, so through the held
    /// instance the first tick's figure was every tick's figure and the low-storage warning could not
    /// see the disk fill. A new instance per call starts with an empty cache. Not
    /// `removeCachedResourceValue(forKey:)` on a copy: measured, that re-reads the capacity but keeps
    /// the instance's cached idea of which volume the path is on, so a fresh instance is the read
    /// that asks the file system everything.
    ///
    /// **Uncached is not cheap (F877).** Each call is a full volume-capacity query, measured on this
    /// Mac at 7.4–24 ms spaced a second apart and up to 50 ms in a tight loop (the lane X review and
    /// F877's re-run of its probe), against 0.007 ms for the plain `volumeAvailableCapacityKey`. So nothing calls it on `captureQueue`:
    /// `FreeSpaceSampler` calls it on its own utility queue, at most every ten seconds.
    static func availableStorageBytes(at directory: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: directory.path, isDirectory: true)
        let values = try? fresh.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}


/// Converts captured `CMSampleBuffer`s to mono float32 and hands them to a `FloatTrackFile`.
///
/// The split is F278's: everything AVFoundation-shaped stays here, exercised by a live capture or by
/// a hand-built `CMSampleBuffer` (F856), and the file — the writes, the flush cadence, the frame count — sits in
/// `FloatTrackFile`, where `FloatTrackFileTests` can observe the durability behaviour F276 shipped
/// without being able to test.
final class FloatTrackWriter {
    private let targetFormat: AVAudioFormat
    private let track: FloatTrackFile
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private(set) var firstPresentationTime: Double?
    /// Frames of silence written to fill spans the stream skipped (F151). Reported so a recording
    /// can say it has gaps rather than quietly containing them. Not the restart's padding, which
    /// `appendSilence` writes and the manifest records as a padded gap of its own (F282).
    var droppedFrames: Int64 { track.gapPaddedFrames }
    /// Frames written twice, and left out, to keep a drifting clock on time (F556). Logged at Stop,
    /// never persisted: they are the measurement F556 asked for, not a property of the recording.
    var driftRepeatedFrames: Int64 { track.driftRepeatedFrames }
    var driftSkippedFrames: Int64 { track.driftSkippedFrames }
    var frameCount: Int64 { track.frameCount }

    init(
        outputURL: URL,
        targetSampleRate: Double,
        deviceSync: @escaping FloatTrackFile.DeviceSync = FloatTrackFile.fullFsync
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.conversionFailed("Unsupported output audio format")
        }
        targetFormat = format
        track = try FloatTrackFile(url: outputURL, sync: deviceSync)
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> RecordingAudioLevel? {
        guard !track.isFinished,
              let description = sampleBuffer.formatDescription else {
            return nil
        }
        // Built by `inputFormat(of:)`, which can say no, and a no is one failed write (F856): the
        // sample handler records it like any other (`_streamError`, `recordWriteOutcome`) and the
        // other track keeps recording. Never `AVAudioFormat(cmAudioFormatDescription:)`, whose nil
        // nothing could check — see `inputFormat(of:)`.
        guard let inputFormat = Self.inputFormat(of: description) else {
            throw AudioCaptureError.conversionFailed("Could not read the captured audio's format")
        }

        // The list is sized by asking CoreMedia, not by counting channels (F875). `CMSampleBuffer.h:875`:
        // `bufferListOut` is "Allocated by the caller, sized as specified by bufferListSizeNeededOut".
        // One buffer per channel is right only for a deinterleaved buffer. An interleaved one has ONE
        // buffer holding every channel, and CoreMedia answers any other size, larger included, with
        // `kCMSampleBufferError_ArrayTooSmall` (-12737; the header's "insufficient" undersells it). So
        // an interleaved microphone with 2 or more channels threw on every buffer and recorded nothing.
        // Both calls pass the same flags, so the size asked about is the size used.
        let listFlags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        var bufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: listFlags,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioCaptureError.conversionFailed("Could not read captured audio (\(sizeStatus))")
        }
        let listStorage = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listStorage.deallocate() }
        let bufferList = listStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: listFlags,
            blockBufferOut: &retainedBlockBuffer
        )
        // Checked before anything reads the list: on failure CoreMedia has filled nothing in.
        guard status == noErr else {
            throw AudioCaptureError.conversionFailed("Could not read captured audio (\(status))")
        }
        // Inside the bridge (F385): `AVAudioBuffer.h` documents `initWithPCMFormat:bufferListNoCopy:`
        // as raising "if the format is not PCM" — and `inputFormat` is not a format this code
        // chooses, it is whatever `CMAudioFormatDescription` the captured buffer carries, a device
        // condition the caller cannot pre-check. `targetFormat` below has no such exposure: it is
        // built once, in `init`, from `commonFormat: .pcmFormatFloat32`, which is PCM by
        // construction — there is nothing external to raise on, so it is not wrapped.
        var rawInputBuffer: AVAudioPCMBuffer?
        var raised: NSError?
        let completed = WMRunCatchingObjCExceptions({
            rawInputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: bufferList,
                deallocator: nil
            )
        }, &raised)
        guard completed else {
            throw AudioCaptureError.conversionFailed(
                "Could not read captured audio (\(raised?.localizedDescription ?? "the format was rejected"))"
            )
        }
        guard let inputBuffer = rawInputBuffer else {
            throw AudioCaptureError.conversionFailed("Could not read captured audio (the buffer list was refused)")
        }
        // `clamping:`, not a bare conversion: `numSamples` is a signed `CMItemCount` and
        // `UInt32(Int)` traps on a negative or oversized value (F376's sweep).
        inputBuffer.frameLength = AVAudioFrameCount(clamping: sampleBuffer.numSamples)

        // Channels are averaged by hand before the converter sees them (F659). The microphone track
        // arrives in "the selected microphone capture device's native format" (`SCStream.h`, on
        // `SCStreamOutputTypeMicrophone`), a multi-input interface can report a layout that names no
        // speakers, and the converter folded such a layout into silence. `inputBuffer` itself is still what the meter
        // reads below, because clipping is counted per captured channel (F419).
        guard let mono = MonoDownmixConverter.averagedToMono(inputBuffer) else {
            throw AudioCaptureError.conversionFailed("Could not mix the captured channels")
        }

        // Not inside the bridge (F385): `AVAudioConverter.h`'s `initFromFormat:toFormat:`
        // documents only "returns nil if the format conversion is not possible" — no sentence
        // anywhere in the header names an exception, unlike `AVAudioBuffer.h`'s two PCM
        // initializers above. `MonoDownmixConverter.make` already models that one documented
        // failure as the `nil` the `guard` below reads.
        if converter == nil || converterInputFormat != mono.format {
            converter = MonoDownmixConverter.make(from: mono.format, to: targetFormat)
            converterInputFormat = mono.format
        }
        guard let converter else {
            throw AudioCaptureError.conversionFailed("Could not create an audio converter")
        }

        let ratio = targetFormat.sampleRate / mono.format.sampleRate
        // `saturating:`, matching `DictationTapConverter` — this function's deliberate mirror,
        // which fixed the same line in F356 while this one kept the bare conversion that traps
        // (F376). An inconsistency between two copies of one function is how the next reader
        // learns the wrong rule.
        let capacity = AVAudioFrameCount(saturating: ceil(Double(mono.frameLength) * ratio) + 32)
        // Not inside the bridge (F385): `AVAudioBuffer.h` documents the SAME exception for this
        // initializer as for the bridged one above — "An exception is raised if the format is not
        // PCM" — so the header does not distinguish them; what does is `targetFormat`, built once
        // in `init` from `commonFormat: .pcmFormatFloat32` and never reassigned (PCM by
        // construction), so nothing external can make this raise and there is nothing here for
        // the bridge to guard against. The only documented failure mode left (a capacity too
        // large for a `UInt32` byte count) already returns nil, which the `guard` below handles.
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw AudioCaptureError.conversionFailed("Could not allocate an audio buffer")
        }

        var conversionError: NSError?
        var suppliedInput = false
        let conversionStatus = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard conversionStatus != .error,
              conversionError == nil,
              let samples = outputBuffer.floatChannelData?.pointee else {
            throw AudioCaptureError.conversionFailed(
                conversionError?.localizedDescription ?? "Audio conversion failed"
            )
        }

        if firstPresentationTime == nil {
            firstPresentationTime = sampleBuffer.presentationTimeStamp.seconds
        }
        // F151 and F556, in `FloatTrackFile.appendCaptured`: a span the stream skipped is padded
        // with silence BEFORE this buffer, so its samples land at their true offset, and a track
        // drifting off its clock is steered back by a single frame. Without the padding, dropped or
        // stalled buffers pack the rest of the track earlier than it happened; without the steering,
        // a slow device clock reached the gap tolerance every few minutes and got 10 ms of zeros.
        //
        // The same invariant F275 restores after a restart (`sample offset == elapsed time`), for
        // causes that have to be detected rather than announced. A healthy buffer is written as it
        // is, which is the case that has to stay free.
        //
        // The pointer is passed straight through rather than copied into an array, because this runs
        // on the `sampleHandlerQueue` for every buffer; the write and its periodic device flush (F276)
        // belong to `FloatTrackFile`.
        let presentationTime = sampleBuffer.presentationTimeStamp.seconds
        try track.appendCaptured(
            samples,
            frameCount: Int(outputBuffer.frameLength),
            presentationOffset: presentationTime - (firstPresentationTime ?? presentationTime),
            // The writer's OWN output rate, not the engine's constant: this compares against
            // `track.frameCount`, which counts frames at the rate this writer converts to.
            sampleRate: targetFormat.sampleRate
        )
        // The level and the clipping count are `CaptureLevelMeter`'s, so a test can drive the
        // production computation without a `CMSampleBuffer` (F419).
        return CaptureLevelMeter.measure(input: inputBuffer, output: outputBuffer)
    }

    /// The audio format a captured buffer's description describes, or nil when it describes none
    /// (F856).
    ///
    /// **Why not `AVAudioFormat(cmAudioFormatDescription:)`.** `AVAudioFormat.h:149` says it "fails
    /// (returns nil)" for an invalid description, but it is imported into Swift as non-optional, so
    /// the nil came back as an object no `guard` could see. A description with more than 2 channels
    /// and no channel layout is invalid to it, since "Only formats with more than 2 channels are
    /// required to have channel layouts" (`AVAudioFormat.h:203`), and the microphone track arrives in
    /// the device's native format (`SCStream.h:26`). Measured: the nil read as 0 channels, and the
    /// buffer built on it crashed with SIGSEGV inside `AVAudioPCMBuffer`'s initializer, which the
    /// exception bridge around it cannot catch. AGENTS.md: make the crash impossible rather than plan
    /// to handle it. So the format is built here, from parts each of which can say no:
    ///
    /// - `CMAudioFormatDescriptionGetStreamBasicDescription` returns NULL for a non-audio description
    ///   (`CMFormatDescription.h`), and a stream with no channels or no rate is no stream.
    /// - `CMAudioFormatDescriptionGetChannelLayout`: "AudioChannelLayouts are optional; this API will
    ///   return NULL if one does not exist." A layout is kept only when it names exactly the
    ///   stream's channel count. Reading `channelCount` also catches `AVAudioChannelLayout(layout:)`
    ///   returning its own unchecked nil, which reads as 0. It is another non-optional initializer.
    /// - With no usable layout and more than 2 channels, `DiscreteInOrder | N`. The labels cost
    ///   nothing: `MonoDownmixConverter.averagedToMono` averages every channel and reads none of
    ///   them (F659). `AVAudioChannelLayout.h`: `initWithLayoutTag:` returns nil only for the
    ///   `UseChannelDescriptions` and `UseChannelBitmap` tags.
    /// - `AVAudioFormat(streamDescription:channelLayout:)` is the failable initializer:
    ///   `AVAudioFormat.h:74`, it "fails (returns nil) unless layout is non-nil" for more than 2
    ///   channels. No exception is documented for any of these calls.
    ///
    /// Wherever the old initializer produced a format, this one has the same channel count, sample
    /// format and interleaving, and the same layout tag (measured on mono, stereo with and without a
    /// layout, interleaved Int16, and 4 channels with `DiscreteInOrder` and `Unknown`).
    static func inputFormat(of description: CMAudioFormatDescription) -> AVAudioFormat? {
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }
        let channels = streamDescription.pointee.mChannelsPerFrame
        guard channels > 0, streamDescription.pointee.mSampleRate > 0 else { return nil }
        var layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)
            .map { AVAudioChannelLayout(layout: $0) }
        if let given = layout, given.channelCount != channels {
            layout = nil
        }
        if layout == nil, channels > 2 {
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        }
        return AVAudioFormat(streamDescription: streamDescription, channelLayout: layout)
    }

    /// Writes a gap the capture could not record as silence, keeping offsets honest (F275).
    func appendSilence(frames: Int64) throws {
        try track.appendSilence(frames: frames)
    }

    #if DEBUG
    /// Test seam (F292): frames with a stated start, standing in for converted sample buffers.
    func appendTestFrames(_ frames: Int64, firstPresentationTime start: Double) throws {
        if firstPresentationTime == nil { firstPresentationTime = start }
        try track.appendSilence(frames: frames)
    }

    /// Test seam (F632): thrown by the next `finish()`, once, after the track is finalized. The
    /// only step of `FloatTrackFile.finish` that throws is a `close()` that fails after the flush,
    /// and a failed finish there leaves the track finished, so that is the failure this stands in
    /// for. Set before the engine publishes the writer; read and cleared on the capture queue.
    var finishFailureForTesting: Error?

    /// Test seam (F734): told the track's URL when `cancel()` runs, so a test can ask where a
    /// discard happened. `FloatTrackFile.cancel` never reaches the `DeviceSync` that F632's probe
    /// observes. Set before the engine publishes the writer.
    var cancelProbeForTesting: ((URL) -> Void)?
    #endif

    func finish() throws -> FloatTrack {
        // `FloatTrackFile.finish` is idempotent, which this path needs: `preservePartialTracks()`
        // finalizes both tracks on the abort routes (`start()`'s catch and `stop()`'s two), and
        // `stop()`'s second catch runs after `finishTrackWriters()` may already have finished one.
        // It flushes the tail before anyone reads it back.
        try track.finish()
        #if DEBUG
        if let failure = finishFailureForTesting {
            finishFailureForTesting = nil
            throw failure
        }
        #endif
        return FloatTrack(
            url: track.url,
            firstPresentationTime: firstPresentationTime,
            frameCount: track.frameCount
        )
    }

    func cancel() {
        #if DEBUG
        cancelProbeForTesting?(track.url)
        #endif
        track.cancel()
    }
}



private extension DispatchQueue {
    func flush() async {
        await withCheckedContinuation { continuation in
            async { continuation.resume() }
        }
    }
}
