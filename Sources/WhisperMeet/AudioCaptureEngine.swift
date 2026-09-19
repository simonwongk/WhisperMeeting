import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.whispermeet.app",
        category: "RecordingStartup"
    )

    private let captureQueue = DispatchQueue(label: "com.whispermeet.audio-capture", qos: .userInitiated)
    private var stream: SCStream?
    private var systemWriter: FloatTrackWriter?
    private var microphoneWriter: FloatTrackWriter?
    private var sessionDirectory: URL?
    private var startedAt: Date?
    private var streamError: Error?
    /// The stream itself stopped — as opposed to one buffer failing to convert or write, which also
    /// sets `streamError` (F292). Only a real death means the audio ends early.
    private var streamDied = false
    /// Bumped by every `reset()` (F292). A restart remembers the value it started under and, after
    /// each of its awaits, gives up if a stop or cancel has reset the engine in the meantime —
    /// otherwise a restart outliving Stop's bounded wait would start a stream nothing ever stops,
    /// and the next recording's `start()` would find `stream != nil` and silently do nothing.
    private var sessionGeneration = 0
    /// A restart is between tearing down the dead stream and paying its padding (F292). A stop that
    /// lands then — only possible once Stop's bounded wait has run out — is stopping a capture that
    /// had died, and must not treat a half-started stream's refusal to stop as a finishing failure.
    private var restartInProgress = false
    private var healthMonitor: RecordingHealthMonitor?
    private var healthUpdate: (@Sendable (RecordingHealthSnapshot) -> Void)?
    private var healthTimer: DispatchSourceTimer?
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
    private var paddedGaps: [SourceTrackManifest.PaddedGap] = []

    /// Restarts attempted for the current recording, which `CaptureRestartPolicy` bounds (F275).
    private(set) var restartCount = 0

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
        preservingPartialTracks: @escaping () -> Void,
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
            streamError = nil
            streamDied = false
            startedAt = Date()
            // Establish the monitor, callbacks, and level fields BEFORE capture begins so the
            // capture queue never reads or writes them concurrently with this setup. No sample
            // buffers are delivered until startCapture() returns.
            healthMonitor = RecordingHealthMonitor(
                startedAt: ProcessInfo.processInfo.systemUptime
            )
            healthUpdate = onHealthUpdate
            levelsUpdate = onLevels
            levelMeter = RecordingLevelMeter()
            lastLevelsEmittedAt = 0
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
                systemWriter?.cancel()
                microphoneWriter?.cancel()
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
        var captureHadDied = streamDied || restartInProgress
            || (stream == nil && injectedStopCapture == nil)

        do {
            if let injectedStopCapture {
                try await injectedStopCapture()
            } else if let stream {
                // Stopping a stream ScreenCaptureKit already stopped throws; that is the death we
                // already know about, not a new failure.
                if captureHadDied {
                    try? await stream.stopCapture()
                } else {
                    try await stream.stopCapture()
                }
            }
        } catch {
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
        stopHealthTimer()
        await captureQueue.flush()

        let systemTrack: FloatTrack
        let microphoneTrack: FloatTrack
        do {
            try injectedFinishTracks?()
            guard let finishedSystemTrack = try systemWriter?.finish(),
                  let finishedMicrophoneTrack = try microphoneWriter?.finish() else {
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
        try mapMixError {
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
        return artifact
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stopHealthTimer()
        await captureQueue.flush()
        systemWriter?.cancel()
        microphoneWriter?.cancel()
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
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        do {
            // F292: a restarted capture's first buffer must land AFTER the silence for the gap.
            try applyPendingRestartPaddingIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            switch outputType {
            case .audio:
                if let level = try systemWriter?.append(sampleBuffer) {
                    healthMonitor?.receive(.systemAudio, level: level, at: now)
                    levelMeter.receive(.systemAudio, level: level, at: now)
                    emitLevelsIfNeeded(at: now)
                }
            case .microphone:
                if let level = try microphoneWriter?.append(sampleBuffer) {
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
            streamError = error
        }
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
        captureQueue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.handleStreamFailure(error)
        }
    }

    /// Records a capture-stream failure. Internal so `StreamFailurePowerAssertionTests` can drive it
    /// without an `SCStream` (F254).
    ///
    /// It deliberately does **not** end the recording activity, which is what it used to do. That
    /// single line put the Mac to sleep five seconds after a lid close, twice, on the user's own
    /// machine — confirmed from `pmset -g log`:
    ///
    ///     15:37:46  Display is turned off
    ///     15:37:46  Released PreventUserIdleSystemSleep "Recording meeting audio" (held 01:03:01)
    ///     15:37:51  Entering Sleep state due to 'Clamshell Sleep'
    ///
    /// The stream is bound to one display (`:139`), so closing the lid kills it; releasing the
    /// assertion in response removed the only thing keeping the machine awake, before a single byte
    /// had been finalized. The assertion is still released in `reset()`, which runs on stop and
    /// cancel — once the recording has actually been dealt with.
    ///
    /// The cost of holding it: if the stream dies and the user never stops the recording, the Mac
    /// will not idle-sleep. That is the right side to err on — a battery cost against losing the
    /// rest of a meeting — and it goes away once something finalizes automatically on stream death
    /// (F253). `RecordingHealthMonitor` already surfaces the dead stream within ~4 s.
    func handleStreamFailure(_ error: Error) {
        streamError = error
        streamDied = true
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
        let generation = sessionGeneration
        restartInProgress = true
        defer { if generation == sessionGeneration { restartInProgress = false } }
        // The death is cleared BEFORE the new stream can start, so a new stream that dies at once
        // records its own death rather than having it erased by a clear that runs after it. Put
        // back if the restart fails, which keeps `hasStreamError` true for the retry.
        let previousError = streamError
        captureQueue.sync {
            streamError = nil
            streamDied = false
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
                try ensureSession(generation)
                setPendingRestartPadding(paddingFrames)
                self.stream = stream
                try await stream.startCapture()
                startedStream = stream
                try ensureSession(generation)
            }
            try captureQueue.sync { try applyPendingRestartPaddingIfNeeded() }
        } catch {
            // A stream this restart started is stopped again whatever went wrong after it started:
            // left running, it would capture into writers that are about to be dropped.
            if let startedStream { try? await startedStream.stopCapture() }
            // Only this recording's state is put back. If a stop or cancel reset the engine while
            // the restart was waiting, the state belongs to nobody — or to the next recording.
            if generation == sessionGeneration {
                if startedStream != nil || injectedRestartCapture == nil { self.stream = nil }
                setPendingRestartPadding(0)
                captureQueue.sync {
                    streamError = streamError ?? previousError ?? error
                    streamDied = true
                }
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
        Self.logger.info(
            "Recording capture restarted after \(paddingFrames) padded frames (restart \(self.restartCount))"
        )
    }

    /// Throws `CancellationError` when a stop or cancel has reset the engine since `generation`.
    private func ensureSession(_ generation: Int) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    /// Silence owed to both tracks by a restart in progress (F292). Read and written only on the
    /// capture queue, which is also where the sample handler runs, so it is paid exactly once.
    private var pendingRestartPadding: Int64 = 0

    func setPendingRestartPadding(_ frames: Int64) {
        captureQueue.sync { pendingRestartPadding = max(0, frames) }
    }

    /// Pays owed restart silence into both tracks and records where it went (F282). Must run on
    /// the capture queue, or in a test with no capture running.
    func applyPendingRestartPaddingIfNeeded() throws {
        guard pendingRestartPadding > 0 else { return }
        let frames = pendingRestartPadding
        pendingRestartPadding = 0
        // Recorded before the padding goes in, so `startSeconds` is where the gap begins. The
        // system track's count is the reference; both tracks get the same amount, which is what
        // keeps them aligned with each other.
        let framesBeforePadding = systemWriter?.frameCount ?? 0
        try systemWriter?.appendSilence(frames: frames)
        try microphoneWriter?.appendSilence(frames: frames)
        paddedGaps.append(
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
    func beginTestTrackSession(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        systemWriter = try FloatTrackWriter(
            outputURL: directory.appendingPathComponent("system-audio.f32"), targetSampleRate: Self.targetSampleRate
        )
        microphoneWriter = try FloatTrackWriter(
            outputURL: directory.appendingPathComponent("microphone-audio.f32"), targetSampleRate: Self.targetSampleRate
        )
        sessionDirectory = directory
        healthMonitor = RecordingHealthMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
    }

    func writeTestFrames(system: Int64, microphone: Int64, systemStart: Double, microphoneStart: Double) throws {
        try systemWriter?.appendTestFrames(system, firstPresentationTime: systemStart)
        try microphoneWriter?.appendTestFrames(microphone, firstPresentationTime: microphoneStart)
    }

    /// A buffer that failed to convert or write while the stream kept running — `streamError`
    /// without a death, which the sample handler's catch produces.
    func recordWriteFailureForTesting(_ error: Error) {
        streamError = error
    }

    var testFrameCounts: (system: Int64, microphone: Int64) {
        (systemWriter?.frameCount ?? 0, microphoneWriter?.frameCount ?? 0)
    }
    #endif

    /// Whether a stream failure has been recorded — `stop()` uses this to preserve partial tracks.
    var hasStreamError: Bool { streamError != nil }

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
        stream = nil
        systemWriter = nil
        microphoneWriter = nil
        sessionDirectory = nil
        startedAt = nil
        streamError = nil
        streamDied = false
        restartInProgress = false
        sessionGeneration += 1
        healthMonitor = nil
        healthUpdate = nil
        levelsUpdate = nil
        injectedStopCapture = nil
        injectedFinishTracks = nil
        injectedPreserveTracks = nil
        // Per recording, not per app run (F275): the policy's bound is "this meeting may restart N
        // times", so carrying the count into the next recording would make a Mac that lost one
        // capture refuse to retry the following one.
        restartCount = 0
        paddedGaps = []
        pendingRestartPadding = 0
        levelMeter = RecordingLevelMeter()
        lastLevelsEmittedAt = 0
    }

    private func preservePartialTracks() {
        if let injectedPreserveTracks {
            injectedPreserveTracks()
        } else {
            _ = try? systemWriter?.finish()
            _ = try? microphoneWriter?.finish()
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
        timer.schedule(deadline: .now(), repeating: 1)
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
        let availableBytes = sessionDirectory.flatMap(Self.availableStorageBytes)
        healthUpdate(healthMonitor.snapshot(
            at: now,
            availableStorageBytes: availableBytes
        ))
    }

    private static func availableStorageBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}


/// Converts captured `CMSampleBuffer`s to mono float32 and hands them to a `FloatTrackFile`.
///
/// The split is F278's: everything AVFoundation-shaped stays here, where it needs a live capture to
/// exercise, and the file — the writes, the flush cadence, the frame count — sits in
/// `FloatTrackFile`, where `FloatTrackFileTests` can observe the durability behaviour F276 shipped
/// without being able to test.
private final class FloatTrackWriter {
    private let targetFormat: AVAudioFormat
    private let track: FloatTrackFile
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private(set) var firstPresentationTime: Double?
    /// Frames of silence written to fill spans the stream skipped (F151). Reported so a recording
    /// can say it has gaps rather than quietly containing them.
    private(set) var droppedFrames: Int64 = 0
    var frameCount: Int64 { track.frameCount }

    init(outputURL: URL, targetSampleRate: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.conversionFailed("Unsupported output audio format")
        }
        targetFormat = format
        track = try FloatTrackFile(url: outputURL)
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> RecordingAudioLevel? {
        guard !track.isFinished,
              let description = sampleBuffer.formatDescription else {
            return nil
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)

        let maximumBuffers = max(1, Int(inputFormat.channelCount))
        let bufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { bufferList.unsafeMutablePointer.deallocate() }
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: bufferList.unsafePointer,
                deallocator: nil
              ) else {
            throw AudioCaptureError.conversionFailed("Could not read captured audio (\(status))")
        }
        inputBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else {
            throw AudioCaptureError.conversionFailed("Could not create an audio converter")
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 32)
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
            return inputBuffer
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
        // F151: pad a span the stream skipped, BEFORE writing this buffer, so its samples land at
        // their true offset. Without this, dropped or stalled buffers pack the rest of the track
        // earlier than it happened — shortening the recording, invalidating every timestamp after
        // the gap, and desyncing the two channels, which drop independently.
        //
        // The same invariant F275 restores after a restart (`sample offset == elapsed time`), for a
        // cause that has to be detected rather than announced. Returns 0 on every buffer of a
        // healthy capture, which is the case that has to stay free.
        if let firstPresentationTime {
            let padding = CaptureGapPolicy.paddingFrames(
                presentationOffset: sampleBuffer.presentationTimeStamp.seconds - firstPresentationTime,
                writtenFrames: track.frameCount,
                // The writer's OWN output rate, not the engine's constant: this compares against
                // `track.frameCount`, which counts frames at the rate this writer converts to.
                sampleRate: targetFormat.sampleRate
            )
            if padding > 0 {
                try track.appendSilence(frames: padding)
                droppedFrames += padding
            }
        }
        // The write and its periodic device flush (F276) belong to `FloatTrackFile`; the pointer is
        // passed straight through rather than copied into an array, because this runs on the
        // `sampleHandlerQueue` for every buffer.
        try track.append(samples, frameCount: Int(outputBuffer.frameLength))
        let sampleCount = Int(outputBuffer.frameLength)
        guard sampleCount > 0 else { return .silent }
        var squaredSum: Float = 0
        var peak: Float = 0
        for index in 0..<sampleCount {
            let magnitude = abs(samples[index])
            squaredSum += magnitude * magnitude
            peak = max(peak, magnitude)
        }
        return RecordingAudioLevel(
            rms: sqrt(squaredSum / Float(sampleCount)),
            peak: peak
        )
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
    #endif

    func finish() throws -> FloatTrack {
        // `FloatTrackFile.finish` is idempotent, which this path needs: `preservePartialTracks()`
        // finalizes both tracks on the abort routes (`:201`, `:228`, `:235`, `:250`) and the normal
        // stop finalizes them again at `:243`. It flushes the tail before anyone reads it back.
        try track.finish()
        return FloatTrack(
            url: track.url,
            firstPresentationTime: firstPresentationTime,
            frameCount: track.frameCount
        )
    }

    func cancel() {
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
