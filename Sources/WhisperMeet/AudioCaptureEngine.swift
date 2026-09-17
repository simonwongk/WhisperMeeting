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
        directory: URL
    ) {
        injectedStopCapture = stoppingCapture
        injectedFinishTracks = finishingTracks
        injectedPreserveTracks = preservingPartialTracks
        injectedStartCapture = startingCapture
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
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let contentReadyAt = ProcessInfo.processInfo.systemUptime
            // F254: pin to the MAIN display rather than whichever happens to be first. The stream
            // dies with the display it is filtered on, and in clamshell the built-in one is what
            // goes away — so this is the difference between a docked Mac keeping its capture and
            // losing it. It does not save an undocked lid close; nothing can, because the machine
            // sleeps. See the ticket for the `pmset` chain.
            guard let index = Self.preferredDisplayIndex(
                displayIDs: content.displays.map(\.displayID),
                mainDisplayID: CGMainDisplayID()
            ) else {
                throw AudioCaptureError.noDisplayAvailable
            }
            let display = content.displays[index]

            let excludedApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
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
            self.stream = stream
            sessionDirectory = directory
            streamError = nil
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
        guard let directory = sessionDirectory,
              stream != nil || injectedStopCapture != nil else {
            throw AudioCaptureError.noAudioCaptured
        }
        defer { reset() }

        do {
            if let injectedStopCapture {
                try await injectedStopCapture()
            } else {
                try await stream?.stopCapture()
            }
        } catch {
            stopHealthTimer()
            await captureQueue.flush()
            preservePartialTracks()
            throw error
        }
        stopHealthTimer()
        await captureQueue.flush()

        if let streamError {
            preservePartialTracks()
            throw streamError
        }

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
        try SourceTrackManifest.write(
            system: systemTrack,
            microphone: microphoneTrack,
            sampleRate: Self.targetSampleRate,
            to: directory.appendingPathComponent("source-tracks.json")
        )
        // Capture the health rollup before `reset()` (deferred) nils the monitor.
        let artifact = RecordingArtifact(
            mixedRecordingURL: mixedURL,
            systemTrackURL: systemTrack.url,
            microphoneTrackURL: microphoneTrack.url,
            duration: duration,
            healthReport: healthMonitor?.report()
        )
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
        healthMonitor = nil
        healthUpdate = nil
        levelsUpdate = nil
        injectedStopCapture = nil
        injectedFinishTracks = nil
        injectedPreserveTracks = nil
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


private struct SourceTrackManifest: Codable {
    struct Track: Codable {
        let file: String
        let format: String
        let sampleRate: Double
        let channels: Int
        let frameCount: Int64
        let startOffsetSeconds: Double
    }

    let systemAudio: Track
    let microphoneAudio: Track

    static func write(
        system: FloatTrack,
        microphone: FloatTrack,
        sampleRate: Double,
        to outputURL: URL
    ) throws {
        let starts = [
            system.firstPresentationTime,
            microphone.firstPresentationTime
        ].compactMap { $0 }
        guard let earliestStart = starts.min() else {
            throw AudioCaptureError.noAudioCaptured
        }
        let manifest = Self(
            systemAudio: track(
                system,
                sampleRate: sampleRate,
                earliestStart: earliestStart
            ),
            microphoneAudio: track(
                microphone,
                sampleRate: sampleRate,
                earliestStart: earliestStart
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputURL, options: .atomic)
    }

    private static func track(
        _ track: FloatTrack,
        sampleRate: Double,
        earliestStart: Double
    ) -> Track {
        Track(
            file: track.url.lastPathComponent,
            format: "float32-little-endian",
            sampleRate: sampleRate,
            channels: 1,
            frameCount: track.frameCount,
            startOffsetSeconds: max(
                0,
                (track.firstPresentationTime ?? earliestStart) - earliestStart
            )
        )
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
