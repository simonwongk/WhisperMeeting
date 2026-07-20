import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WhisperCore

struct RecordingArtifact: Sendable {
    let mixedRecordingURL: URL
    let systemTrackURL: URL
    let microphoneTrackURL: URL
    let duration: TimeInterval
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

    // Fast, throttled level stream that drives the live volume bar, separate from the 1 Hz health
    // snapshot used for warnings.
    private var levelsUpdate: (@Sendable (RecordingLevels) -> Void)?
    private var latestMicrophoneLevel: RecordingAudioLevel = .silent
    private var latestSystemLevel: RecordingAudioLevel = .silent
    private var lastLevelsEmittedAt: TimeInterval = 0
    private static let levelsEmitInterval: TimeInterval = 1.0 / 15.0

    func start(
        in directory: URL,
        onHealthUpdate: @escaping @Sendable (RecordingHealthSnapshot) -> Void,
        onLevels: @escaping @Sendable (RecordingLevels) -> Void
    ) async throws {
        guard stream == nil else { return }
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
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw AudioCaptureError.noDisplayAvailable
            }

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
            latestMicrophoneLevel = .silent
            latestSystemLevel = .silent
            lastLevelsEmittedAt = 0
            try await stream.startCapture()
            beginRecordingActivity()
            startHealthTimer()
        } catch {
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
        guard let stream, let directory = sessionDirectory else {
            throw AudioCaptureError.noAudioCaptured
        }

        do {
            try await stream.stopCapture()
        } catch {
            stopHealthTimer()
            await captureQueue.flush()
            preservePartialTracks()
            reset()
            throw error
        }
        stopHealthTimer()
        await captureQueue.flush()

        if let streamError {
            preservePartialTracks()
            reset()
            throw streamError
        }

        guard let systemTrack = try systemWriter?.finish(),
              let microphoneTrack = try microphoneWriter?.finish() else {
            reset()
            throw AudioCaptureError.noAudioCaptured
        }
        defer { reset() }
        guard systemTrack.frameCount > 0 || microphoneTrack.frameCount > 0 else {
            throw AudioCaptureError.noAudioCaptured
        }

        let mixedURL = directory.appendingPathComponent("meeting.wav")
        let duration = try FloatTrackMixer.mix(
            system: systemTrack,
            microphone: microphoneTrack,
            sampleRate: Self.targetSampleRate,
            outputURL: mixedURL
        )
        try SourceTrackManifest.write(
            system: systemTrack,
            microphone: microphoneTrack,
            sampleRate: Self.targetSampleRate,
            to: directory.appendingPathComponent("source-tracks.json")
        )
        let artifact = RecordingArtifact(
            mixedRecordingURL: mixedURL,
            systemTrackURL: systemTrack.url,
            microphoneTrackURL: microphoneTrack.url,
            duration: duration
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
                    latestSystemLevel = level
                    emitLevelsIfNeeded(at: now)
                }
            case .microphone:
                if let level = try microphoneWriter?.append(sampleBuffer) {
                    healthMonitor?.receive(.microphone, level: level, at: now)
                    latestMicrophoneLevel = level
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
    private func emitLevelsIfNeeded(at time: TimeInterval) {
        guard let levelsUpdate else { return }
        guard time - lastLevelsEmittedAt >= Self.levelsEmitInterval else { return }
        lastLevelsEmittedAt = time
        levelsUpdate(RecordingLevels(
            microphone: latestMicrophoneLevel,
            systemAudio: latestSystemLevel
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureQueue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.streamError = error
            self.endRecordingActivity()
        }
    }

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
        latestMicrophoneLevel = .silent
        latestSystemLevel = .silent
        lastLevelsEmittedAt = 0
    }

    private func preservePartialTracks() {
        _ = try? systemWriter?.finish()
        _ = try? microphoneWriter?.finish()
    }

    private func beginRecordingActivity() {
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Recording meeting audio"
        )
    }

    private func endRecordingActivity() {
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
        let availableBytes = sessionDirectory.flatMap(Self.availableStorageBytes)
        healthUpdate(healthMonitor.snapshot(
            at: ProcessInfo.processInfo.systemUptime,
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

private struct FloatTrack {
    let url: URL
    let firstPresentationTime: Double?
    let frameCount: Int64
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

private final class FloatTrackWriter {
    private let outputURL: URL
    private let targetFormat: AVAudioFormat
    private let handle: FileHandle
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private(set) var firstPresentationTime: Double?
    private(set) var frameCount: Int64 = 0
    private var isFinished = false

    init(outputURL: URL, targetSampleRate: Double) throws {
        self.outputURL = outputURL
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.conversionFailed("Unsupported output audio format")
        }
        targetFormat = format
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: outputURL)
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> RecordingAudioLevel? {
        guard !isFinished,
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
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
        handle.write(Data(bytes: samples, count: byteCount))
        frameCount += Int64(outputBuffer.frameLength)
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
        if !isFinished {
            try handle.close()
            isFinished = true
        }
        return FloatTrack(
            url: outputURL,
            firstPresentationTime: firstPresentationTime,
            frameCount: frameCount
        )
    }

    func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: outputURL)
        isFinished = true
    }
}

private enum FloatTrackMixer {
    static func mix(
        system: FloatTrack,
        microphone: FloatTrack,
        sampleRate: Double,
        outputURL: URL
    ) throws -> TimeInterval {
        let starts = [system.firstPresentationTime, microphone.firstPresentationTime].compactMap { $0 }
        guard let earliestStart = starts.min() else {
            throw AudioCaptureError.noAudioCaptured
        }
        let systemPadding = paddingFrames(
            firstPresentationTime: system.firstPresentationTime,
            earliestStart: earliestStart,
            sampleRate: sampleRate
        )
        let microphonePadding = paddingFrames(
            firstPresentationTime: microphone.firstPresentationTime,
            earliestStart: earliestStart,
            sampleRate: sampleRate
        )
        let totalFrames = max(
            systemPadding + system.frameCount,
            microphonePadding + microphone.frameCount
        )

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        output.write(Data(repeating: 0, count: 44))

        let systemReader = try PaddedFloatReader(url: system.url, paddingFrames: systemPadding)
        let microphoneReader = try PaddedFloatReader(url: microphone.url, paddingFrames: microphonePadding)
        let chunkSize = 8_192
        var writtenFrames: Int64 = 0

        while writtenFrames < totalFrames {
            let count = min(Int64(chunkSize), totalFrames - writtenFrames)
            let systemSamples = systemReader.read(frameCount: Int(count))
            let microphoneSamples = microphoneReader.read(frameCount: Int(count))
            var pcm = [Int16](repeating: 0, count: Int(count))
            for index in pcm.indices {
                let systemSample = systemSamples[index]
                let microphoneSample = microphoneSamples[index]
                let bothActive = abs(systemSample) > 0.01 && abs(microphoneSample) > 0.01
                let mixed = bothActive
                    ? (systemSample + microphoneSample) * 0.5
                    : (systemSample + microphoneSample) * 0.95
                pcm[index] = Int16(max(-1, min(1, mixed)) * Float(Int16.max))
            }
            pcm.withUnsafeBytes { output.write(Data($0)) }
            writtenFrames += count
        }

        let dataByteCount = UInt32(clamping: writtenFrames * 2)
        try output.seek(toOffset: 0)
        output.write(wavHeader(
            sampleRate: UInt32(sampleRate),
            dataByteCount: dataByteCount
        ))
        return Double(writtenFrames) / sampleRate
    }

    private static func paddingFrames(
        firstPresentationTime: Double?,
        earliestStart: Double,
        sampleRate: Double
    ) -> Int64 {
        guard let firstPresentationTime else { return 0 }
        return max(0, Int64((firstPresentationTime - earliestStart) * sampleRate))
    }

    private static func wavHeader(sampleRate: UInt32, dataByteCount: UInt32) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 &+ dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private final class PaddedFloatReader {
    private let handle: FileHandle
    private var paddingFrames: Int64

    init(url: URL, paddingFrames: Int64) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.paddingFrames = paddingFrames
    }

    deinit {
        try? handle.close()
    }

    func read(frameCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        var destinationIndex = 0
        if paddingFrames > 0 {
            let silenceCount = min(Int64(frameCount), paddingFrames)
            paddingFrames -= silenceCount
            destinationIndex += Int(silenceCount)
        }
        guard destinationIndex < frameCount else { return result }

        let requestedBytes = (frameCount - destinationIndex) * MemoryLayout<Float>.size
        guard let data = try? handle.read(upToCount: requestedBytes), !data.isEmpty else {
            return result
        }
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            for index in 0..<source.count {
                result[destinationIndex + index] = source[index]
            }
        }
        return result
    }
}

private extension DispatchQueue {
    func flush() async {
        await withCheckedContinuation { continuation in
            async { continuation.resume() }
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
