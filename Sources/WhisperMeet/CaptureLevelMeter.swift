import AVFoundation
import WhisperCore

/// The level and clipping measurement for one captured buffer (F346, F419).
///
/// Lifted out of `FloatTrackWriter.append` so a test can drive the production computation with an
/// `AVAudioPCMBuffer` it built itself — `append` takes a `CMSampleBuffer`, which no test here
/// constructs (`FloatTrackFileTests`).
enum CaptureLevelMeter {
    /// `input` is the buffer as captured; `output` is the same audio after `MonoDownmixConverter`.
    static func measure(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer) -> RecordingAudioLevel {
        let sampleCount = Int(output.frameLength)
        guard sampleCount > 0, let samples = output.floatChannelData?.pointee else { return .silent }
        var squaredSum: Float = 0
        var peak: Float = 0
        // `peak` and `rms` stay on the mix: they drive the live meter and describe the file the
        // user has. `peak` is clamped to 1 by `RecordingAudioLevel`, so by the time anything
        // downstream sees it, "touched full scale once" and "flat-topped for a third of the
        // buffer" are the same number — which is why the count below exists (F346).
        var framesAtFullScaleAfterDownmix = 0
        for index in 0..<sampleCount {
            let magnitude = abs(samples[index])
            squaredSum += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= RecordingHealthMonitor.fullScaleFloor { framesAtFullScaleAfterDownmix += 1 }
        }
        // F419, the user's decision: count clipping per input channel, BEFORE the downmix.
        // Clipping is distortion that already happened at the source, and averaging scales the
        // flattened waveform without unflattening it — a full-scale right channel under a silent
        // left mixes to 0.5 and the post-downmix count said 0. F346 counted the mix (after F398)
        // and, before F398, the left channel only.
        //
        // The count is still in frames, not frames × channels: a frame counts once when ANY
        // channel is at the rail. I chose that so `framesMeasured` keeps its persisted unit,
        // `ClippedSecond`'s "count is how long the clipping lasted" still holds, and
        // `atFullScale <= measured` stays true by construction for the advisory's guards (F400).
        //
        // Input frames are mapped to the output rate, because `framesMeasured` is output frames;
        // at 48 kHz in and out (what `AudioCaptureEngine` asks ScreenCaptureKit for) the ratio is 1
        // and the mapping is exact. The larger of the two counts is kept, so nothing the mix
        // counted before is lost; a format the per-channel read does not cover (not float32)
        // falls back to the count over the converted buffer, which is what every build before
        // F419 reported.
        var framesAtFullScale = framesAtFullScaleAfterDownmix
        if let inputFrames = framesAtFullScaleAcrossChannels(input) {
            let ratio = output.format.sampleRate / input.format.sampleRate
            let mapped = Int(saturating: (Double(inputFrames) * ratio).rounded())
            framesAtFullScale = max(framesAtFullScale, min(sampleCount, mapped))
        }
        return RecordingAudioLevel(
            rms: sqrt(squaredSum / Float(sampleCount)),
            peak: peak,
            framesMeasured: sampleCount,
            framesAtFullScale: framesAtFullScale
        )
    }

    /// Input frames where at least one channel is at `fullScaleFloor`, or nil when the format is
    /// one this does not read. Float32 only, interleaved or not — `floatChannelData` is nil for
    /// anything else, and `stride` is the channel count for interleaved buffers and 1 otherwise.
    static func framesAtFullScaleAcrossChannels(_ buffer: AVAudioPCMBuffer) -> Int? {
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let stride = buffer.stride
        var counted = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                // `AVAudioBuffer.h`: there is one pointer per channel in both layouts, and a
                // channel's consecutive samples are `stride` apart — into one shared chunk when
                // interleaved, into separate ones otherwise.
                let sample = channels[channel][frame * stride]
                if abs(sample) >= RecordingHealthMonitor.fullScaleFloor {
                    counted += 1
                    break
                }
            }
        }
        return counted
    }
}
