import AVFoundation
import WhisperCore

protocol DictationRecording: AnyObject {
    var isRecording: Bool { get }
    func requestPermission() async -> Bool
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws
    func stop() throws -> (url: URL, duration: TimeInterval)
    func cancel()
}

/// Mic-only capture for quick dictation. Uses AVAudioEngine (NOT ScreenCaptureKit) so dictation
/// never requires Screen Recording permission. Produces a 16 kHz mono WAV in the temp dir.
///
/// Thread model: the input tap runs on an AVAudioEngine-owned thread; it converts each buffer using
/// converter/format captured as locals (never shared state), then hands the resulting samples to
/// `processingQueue` — the ONLY place `samples` is touched. `stop()`/`cancel()` remove the tap and
/// then drain `processingQueue` (a `sync` barrier) before reading, so no in-flight tap chunk can
/// race the read. This mirrors the tap+queue+flush discipline `AudioCaptureEngine` already uses.
final class MicDictationRecorder: DictationRecording, @unchecked Sendable {
    enum RecorderError: Error {
        case audioFormatUnavailable
        case notRecording
        case noAudioCaptured
    }

    private let engine = AVAudioEngine()
    private let targetSampleRate = Double(DictationCaptureLimits.sampleRate)
    private let processingQueue = DispatchQueue(label: "com.whispermeet.dictation.mic")
    // The controller normally finalizes at 120 seconds. This independent hard limit prevents the
    // audio queue from growing without bound if the main actor is temporarily unable to fire the
    // watchdog.
    private var sampleBuffer = BoundedAudioSampleBuffer(
        capacity: DictationCaptureLimits.maximumSampleCount
    )
    private(set) var isRecording = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            inputFormat.sampleRate > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw RecorderError.audioFormatUnavailable
        }

        processingQueue.sync { sampleBuffer.removeAll(keepingCapacity: true) }

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, converter: converter, outputFormat: outputFormat, onLevel: onLevel)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Runs on the tap thread. Converts the live buffer to 16 kHz mono using the captured converter,
    /// then hands the samples to `processingQueue` (the engine's buffer is not retained past here).
    private func handleTap(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        var chunk = [Float](repeating: 0, count: frames)
        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let value = channel[index]
            chunk[index] = value
            sumOfSquares += value * value
        }
        let level = min(1, (sumOfSquares / Float(frames)).squareRoot() * 8)

        processingQueue.async {
            self.sampleBuffer.append(contentsOf: chunk)
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        let captured: [Float] = processingQueue.sync { sampleBuffer.samples }
        guard !captured.isEmpty else { throw RecorderError.noAudioCaptured }

        let data = WAVWriter.wavData(from: captured, sampleRate: Int(targetSampleRate))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try data.write(to: url)
        let duration = Double(captured.count) / targetSampleRate
        return (url, duration)
    }

    func cancel() {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        processingQueue.sync { sampleBuffer.removeAll() }
    }
}
