import Foundation

/// Whether a Quick Dictation clip holds speech, by a voice-activity detector rather than a level
/// (F846). F599's level floor stops near-silence only: Whisper Turbo answered all 22 of lane K's
/// synthetic noise clips with invented text ("Thank you.", "You", "E aí", "Продолжение следует..."),
/// up to −35 dBFS, and above about −54 dBFS noise is as loud as quiet speech both engines transcribe
/// correctly, so no level can separate them. The app runs FluidAudio's Silero VAD over the clip
/// (`SileroDictationSpeechDetector`) and asks this type what the probabilities mean.
///
/// The rule: speech when any 256 ms chunk reaches `speechThreshold`. Measured with the pinned model
/// over lane K's clips: every one of the 96 speech clips, down to −54 dBFS, reaches 1.000 in some
/// chunk, and no noise clip passes 0.325 in any chunk (white noise at −55 dBFS is the highest), so
/// every threshold from 0.40 to 0.85 skips 22/22 noise clips and refuses 0/96 speech clips. 0.5 is
/// Silero's own customary threshold and sits in the middle of that margin.
///
/// Only Whisper Turbo is gated (`gates(_:)`): Qwen3-ASR returned empty text on all 22 noise clips,
/// so a detector in front of it could only ever refuse words.
public enum DictationVoiceActivity {
    public static let speechThreshold: Float = 0.5

    /// The highest chunk probability, ignoring any value that is not a number; nil when there is
    /// nothing to judge — and then the caller transcribes, as it did before F846.
    public static func peak(of chunkProbabilities: [Float]) -> Float? {
        chunkProbabilities.filter(\.isFinite).max()
    }

    /// Whether a clip whose loudest-chunk probability is `peakProbability` holds speech.
    public static func isSpeech(peakProbability: Float) -> Bool {
        peakProbability >= speechThreshold
    }

    /// Whether the detector runs before `engine` at all.
    public static func gates(_ engine: DictationTranscriptionEngine) -> Bool {
        switch engine {
        case .whisperTurbo: true
        case .qwenBalanced: false
        }
    }
}
