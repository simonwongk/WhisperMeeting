import AVFoundation

/// Builds the one converter shape this app uses: some captured format down to mono float32 (F398).
///
/// This exists because the decision it makes is invisible at the call site. `AVAudioConverter`
/// defaults `downmix` to `NO`, and with it off a stereo-to-mono conversion is a **remap** — it
/// keeps channel 0 and discards the rest. `AVAudioConverter.h:211-216`: "If YES and channel
/// remapping is necessary, then channels will be mixed as appropriate instead of remapped. Default
/// value is NO."
///
/// Nothing about `AVAudioConverter(from: inputFormat, to: targetFormat)` looks wrong, which is why
/// two separate call sites had it for as long as they existed and neither review caught it. So the
/// decision is made in one place that a test can point at, rather than restated at each site.
enum MonoDownmixConverter {
    /// A converter from `input` to `target`, mixing rather than discarding surplus input channels.
    static func make(from input: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: input, to: target) else { return nil }
        // Only when channels actually have to be folded. Setting it unconditionally would be
        // harmless today, but the guard is what makes the single-channel case provably the path
        // it has always been — and a mono input is the overwhelmingly common one for dictation.
        if input.channelCount > target.channelCount {
            converter.downmix = true
        }
        return converter
    }
}
