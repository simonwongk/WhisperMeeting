// Sources/WhisperMeet/Dictation/MicDictationRecorder.swift
import AVFoundation
import WhisperCore

/// Mic-only capture for quick dictation. Uses AVAudioEngine (NOT ScreenCaptureKit) so dictation
/// never requires Screen Recording permission. Produces a 16 kHz mono WAV in the temp dir.
final class MicDictationRecorder: @unchecked Sendable {
    enum RecorderError: Error { case notRecording }

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var onLevel: (@Sendable (Float) -> Void)?
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
        samples.removeAll(keepingCapacity: true)
        self.onLevel = onLevel

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.notRecording }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, outputFormat: outputFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    private func process(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
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
        samples.append(contentsOf: chunk)
        let rms = (sumOfSquares / Float(frames)).squareRoot()
        let level = min(1, rms * 8)
        let handler = onLevel
        DispatchQueue.main.async { handler?(level) }
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        onLevel = nil

        let data = WAVWriter.wavData(from: samples, sampleRate: Int(targetSampleRate))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try data.write(to: url)
        let duration = Double(samples.count) / targetSampleRate
        return (url, duration)
    }

    func cancel() {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        onLevel = nil
        samples.removeAll()
    }
}
