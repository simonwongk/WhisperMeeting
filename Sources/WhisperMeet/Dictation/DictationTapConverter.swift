import AVFoundation
import WhisperCore

/// One converted chunk of microphone audio, at the dictation sample rate.
struct DictationTapChunk: Sendable {
    let samples: [Float]
    /// RMS scaled for the overlay meter, clamped to `0...1`.
    let level: Float
}

/// Converts live microphone tap buffers to the dictation sample rate.
///
/// **The input format is deliberately not pinned, and that is the whole point of this type (F356).**
/// `MicDictationRecorder` used to read `outputFormat(forBus: 0)` once, build an `AVAudioConverter`
/// from it, and hand the same format to `installTap`. Enabling the engine's input stream makes
/// CoreAudio reconfigure the per-process default-device aggregate, so the value was already stale
/// ~20 ms later — and AVFAudio answers a format mismatch by raising an `NSException`, which Swift
/// cannot catch. The app aborted twice on 2026-09-21, once with 48000 Hz stale and once with
/// 24000 Hz stale, which is what proves no pinned value is the right one.
///
/// So the format is read from each buffer as it arrives and the converter rebuilt only when it
/// changes — the same rule `AudioCaptureEngine.append` already follows for meeting capture, which
/// is why the meeting path was never exposed to this.
///
/// Within one capture the rebuild is defence in depth, for a buffer whose format differs from the
/// first one. It does not carry a capture through a device change: on a mid-capture sample-rate or
/// channel-count change the engine stops itself (`AVAudioEngine.h`), `MicDictationRecorder` ends
/// the capture and says so (F357), and the next `start()` builds a fresh converter. A rebuild
/// discards the resampler's priming — measured at 240 samples (15 ms at 16 kHz) going from 48 kHz
/// and 11 samples from 24 kHz — which is a real gap in the audio wherever one happens, so it
/// belongs here rather than only in the test that measured it.
///
/// Thread model: **in production** `convert` is called only from the AVAudioEngine tap thread, which is
/// serial, and nothing else touches the converter for the lifetime of a capture; tests call it directly
/// on the test thread, which is single-threaded and does not weaken that. `@unchecked Sendable` records
/// that the instance crosses into the tap closure and is confined there, matching
/// `MicDictationRecorder`'s own annotation.
final class DictationTapConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// How many times a converter has been built. Only a test reads it — it is the difference
    /// between "tolerates a format change" and "rebuilds on every buffer", which the frame counts
    /// alone cannot tell apart.
    private(set) var rebuildCountForTesting = 0

    init?(targetSampleRate: Double) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = targetFormat
    }

    /// Converts one tap buffer, rebuilding the converter if this buffer's format differs from the
    /// last one's. Returns nil when the buffer yields no usable samples; the caller counts and drops
    /// that chunk rather than failing the capture, because one unusable buffer is not by itself a
    /// failure — whether the capture as a whole yielded nothing is `MicDictationRecorder.stop()`'s
    /// call (F368).
    func convert(_ buffer: AVAudioPCMBuffer) -> DictationTapChunk? {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return nil }

        // Channels are averaged by hand before the converter sees them (F659): an input whose layout
        // names no speakers, which a multi-input interface can report, converted to silence when the
        // converter folded it. So the converter is built from, and rebuilt on a change of, the averaged
        // buffer's format: mono at the input's rate. A channel-count change at one rate no longer
        // rebuilds it, and need not, since the converter never sees the channels.
        guard let mono = MonoDownmixConverter.averagedToMono(buffer) else { return nil }
        let inputFormat = mono.format

        if converter == nil || converterInputFormat != inputFormat {
            converter = MonoDownmixConverter.make(from: mono.format, to: targetFormat)
            // Recorded only on success. If the build failed there is nothing to reuse, so the next
            // buffer must try again rather than be matched against a format no converter exists for.
            converterInputFormat = converter == nil ? nil : inputFormat
            rebuildCountForTesting += 1
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        // `saturating:` rather than a bare conversion: `UInt32(Double)` traps on overflow, and a
        // guard that computes a capacity is exactly where this repo has found that trap before.
        let capacity = AVAudioFrameCount(
            saturating: (Double(mono.frameLength) * ratio).rounded(.up) + 32
        )
        // Belt and braces: `capacity` cannot be zero after the guard above, but a zero frame capacity
        // is one of the argument errors AVFAudio answers by raising, and this file exists because of a
        // raise. Cheaper to keep than to re-derive the reachability argument at each future edit.
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            return nil
        }

        let frames = Int(output.frameLength)
        guard frames > 0 else { return nil }
        var samples = [Float](repeating: 0, count: frames)
        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let value = channel[index]
            samples[index] = value
            sumOfSquares += value * value
        }
        let level = min(1, (sumOfSquares / Float(frames)).squareRoot() * 8)
        return DictationTapChunk(samples: samples, level: level)
    }
}
