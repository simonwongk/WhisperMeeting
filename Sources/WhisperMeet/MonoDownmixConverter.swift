import AVFoundation

/// The one conversion shape this app uses: some captured format down to mono float32 (F398, F659).
///
/// Two steps, and the order is the point. `averagedToMono` folds the channels **by hand**, at the
/// buffer's own sample rate; only then does `make` build an `AVAudioConverter`, which is left with
/// nothing to decide about channels: mono in, mono out, a sample-rate and sample-format change only.
///
/// Why not let the converter fold them. F398 found that `AVAudioConverter` defaults `downmix` to
/// `NO`, which makes a stereo-to-mono conversion a remap that keeps channel 0
/// (`AVAudioConverter.h:212-216`: "If YES and channel remapping is necessary, then channels will be
/// mixed as appropriate instead of remapped. Default value is NO."), and set it. F659 found what
/// `downmix` cannot do: the converter mixes "as appropriate" by reading the channel layout, and a
/// layout that names no speakers — a `DiscreteInOrder` or `Unknown` tag, which a multi-input audio
/// interface can report — converts to **all zeros**, every channel, the first one included. Measured on
/// this Mac with `downmix` on: 2, 3, 4 and 6 discrete channels all read peak 0.0 (the table is in
/// `UnlabelledChannelDownmixTests`). F581 met the same thing in the segment decoder and averaged by
/// hand there. An average reads no layout at all, so no layout can silence it.
///
/// Nothing about `AVAudioConverter(from: inputFormat, to: targetFormat)` looks wrong, which is why
/// two separate call sites had it for as long as they existed and neither review caught it. So the
/// decision is made in one place that a test can point at, rather than restated at each site.
enum MonoDownmixConverter {
    /// A converter from `input` to `target`, or nil when it would have to fold channels.
    ///
    /// The refusal is deliberate (F659): a converter that folds channels is the one that can fold
    /// them into silence, with no error and no sign. A caller that forgets `averagedToMono` gets nil
    /// — `FloatTrackWriter.append` throws, `DictationTapConverter` yields no chunk — which is loud,
    /// instead of a recording of nothing. `AVAudioConverter.h`, `initFromFormat:toFormat:`: "Returns
    /// nil if the format conversion is not possible", the only failure it documents; no exception.
    static func make(from input: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        guard input.channelCount <= target.channelCount else { return nil }
        return AVAudioConverter(from: input, to: target)
    }

    /// `buffer` with every channel averaged into one, as float32 at the buffer's own sample rate. A
    /// one-channel buffer is returned as it is, so the common dictation case takes the path it
    /// always took. Nil when a format or buffer cannot be made or a sample format cannot be read.
    ///
    /// Equal weights, the same rule as F581's segment decoder. For stereo that is the average the
    /// converter's `downmix` produced (F398's right-only 0.5 still reads 0.25, dual-mono 0.5 still
    /// 0.5; the converter's own result was 0.24999999). A speaker-labelled 5.1 is averaged too rather than matrixed — nothing here plays it back,
    /// and a transcript wants every voice present, not a balanced mix.
    static func averagedToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else { return buffer }
        // `AVAudioFormat.h`, `initWithCommonFormat:sampleRate:channels:interleaved:` — nullable; it
        // fails only for more than 2 channels, and this asks for 1. `AVAudioBuffer.h`,
        // `initWithPCMFormat:frameCapacity:` — raises only "if the format is not PCM", and float32 is
        // PCM by construction; it returns nil for a zero-bytes-per-frame format or a capacity whose
        // byte count overflows a `uint32_t`, which the `guard` reads. `max(1, …)` keeps an empty
        // buffer's capacity non-zero: an empty input yields an empty, not a missing, mono buffer.
        guard let floats = float32Samples(of: buffer),
              let channels = floats.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                  channels: 1, interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(1, floats.frameLength)),
              let output = mono.floatChannelData?[0]
        else { return nil }

        // `AVAudioBuffer.h`, `floatChannelData`: "format.channelCount pointers to float. Each of these
        // pointers is to 'frameLength' valid samples, which are spaced by 'stride' samples" — 1 for a
        // deinterleaved buffer, the channel count for an interleaved one, whose pointers "refer into
        // the same chunk of interleaved samples, each offset by 1 frame". So one index reads both.
        let frames = Int(floats.frameLength)
        let stride = floats.stride
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame * stride]
            }
            output[frame] = sum * scale
        }
        mono.frameLength = floats.frameLength
        return mono
    }

    /// `buffer` itself when its samples are already float32 (interleaved or not); otherwise the same
    /// channels, layout and rate converted to deinterleaved float32.
    ///
    /// That conversion keeps every channel, unlike the fold: input and output share one layout and one
    /// channel count, so there is no channel decision for the converter to get wrong. Measured on a
    /// 4-channel `DiscreteInOrder` buffer with a tone only in channel 3 — Int16 interleaved, Int32,
    /// Float64 and interleaved Float32 all came out as per-channel peaks [0, 0, 0, 0.5].
    /// `AVAudioConverter.h`, `convertToBuffer:fromBuffer:error:`, is the "simple conversion … which
    /// does not involve codecs or sample rate conversion", whose output "frameCapacity should be at
    /// least as large as the inputBuffer's frameLength"; it reports failure through its error, which
    /// becomes nil here.
    private static func float32Samples(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32 { return buffer }
        // `AVAudioFormat.h`: a format with more than 2 channels always carries a layout ("Only formats
        // with more than 2 channels are required to have channel layouts"), and the layout initializer
        // requires one ("must not be nil"); 1 or 2 channels without one use the plain initializer.
        let floatFormat: AVAudioFormat?
        if let layout = format.channelLayout {
            floatFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                interleaved: false, channelLayout: layout
            )
        } else {
            floatFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                channels: format.channelCount, interleaved: false
            )
        }
        guard let floatFormat,
              let converter = AVAudioConverter(from: format, to: floatFormat),
              let floats = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: max(1, buffer.frameLength))
        else { return nil }
        do {
            try converter.convert(to: floats, from: buffer)
        } catch {
            return nil
        }
        return floats
    }
}
