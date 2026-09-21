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
/// Thread model: the input tap runs on an AVAudioEngine-owned thread; it converts each buffer
/// through a `DictationTapConverter` created per capture and touched only by that thread, then
/// hands the resulting samples to `processingQueue` — the ONLY place `samples` is touched.
/// `stop()`/`cancel()` remove the tap and then drain `processingQueue` (a `sync` barrier) before
/// reading. `removeTap` is not documented to join a tap block already executing, so a chunk enqueued
/// after the drain can still be dropped — bounded at one buffer, ~21 ms — but nothing can race the
/// read of `samples` itself. This mirrors the tap+queue+flush
/// discipline `AudioCaptureEngine` already uses, and since F356 it also mirrors the rule that
/// matters more: the capture format is read from each buffer, never pinned ahead of the tap.
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
        // The documented availability probe, and both halves of it. AVAudioEngine.h, `inputNode`:
        // "Check for the input node's input format (i.e. hardware format) for non-zero sample rate
        // and channel count to see if input is enabled. Trying to perform input through the input
        // node when it is not enabled or available will cause the engine to throw an error (when
        // possible) or an exception." An exception is not a Swift error and no `catch` below can
        // see it, so this guard is the whole defence (F358). It reads `inputFormat`, not
        // `outputFormat`, because that is the property those sentences name.
        //
        // Be clear about what this does NOT do: the probe is read here and `engine.start()` runs
        // below, so input becoming unavailable in between can still raise — structurally the same
        // read-then-use shape F356 is about. Unlike the tap's format, the API offers no way to
        // decline the claim, so this narrows the window and cannot close it. Tracked as F374.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard
            hardwareFormat.sampleRate > 0,
            hardwareFormat.channelCount > 0,
            let converter = DictationTapConverter(targetSampleRate: targetSampleRate)
        else {
            throw RecorderError.audioFormatUnavailable
        }

        processingQueue.sync { sampleBuffer.removeAll(keepingCapacity: true) }

        // `format: nil`, and that is the F356 fix rather than a simplification. AVAudioNode.h
        // documents the argument as "If non-nil, attempts to apply this as the format of the
        // specified output bus" — so a non-nil value is a claim about the hardware, checked against
        // the live device at install time. Enabling the input stream is itself what reconfigures
        // that device, so a format read beforehand is stale by the time it is validated, and
        // AVFAudio answers a mismatch by raising. nil declines to make the claim: the tap delivers
        // the device's own format and `DictationTapConverter` reads it per buffer. Re-reading the
        // format one line earlier would only have shortened the window, not closed it.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, converter: converter, onLevel: onLevel)
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

    /// Runs on the tap thread. Converts the live buffer at whatever format it arrived in, then
    /// hands the samples to `processingQueue` (the engine's buffer is not retained past here).
    private func handleTap(
        buffer: AVAudioPCMBuffer,
        converter: DictationTapConverter,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        guard let chunk = converter.convert(buffer) else { return }
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
