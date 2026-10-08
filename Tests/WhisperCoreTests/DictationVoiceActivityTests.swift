import Foundation
import Testing
@testable import WhisperCore

// F846 — what a voice-activity detector's chunk probabilities mean for a Quick Dictation clip.

@Test("Speech is a chunk at or above the threshold; anything lower is no speech (F846)")
func voiceActivityThresholdDecides() {
    #expect(DictationVoiceActivity.speechThreshold == 0.5)
    #expect(DictationVoiceActivity.isSpeech(peakProbability: 1.0))
    #expect(DictationVoiceActivity.isSpeech(peakProbability: 0.5))
    // The loudest noise clip measured (white noise at −55 dBFS) peaked at 0.325.
    #expect(!DictationVoiceActivity.isSpeech(peakProbability: 0.325))
    #expect(!DictationVoiceActivity.isSpeech(peakProbability: 0))
}

@Test("The peak ignores values that are not numbers, and nothing to judge is not a verdict (F846)")
func voiceActivityPeakOfChunks() {
    let chunks: [Float] = [0.1, 0.92, 0.3]
    #expect(DictationVoiceActivity.peak(of: chunks) == 0.92)
    let withNaN: [Float] = [.nan, 0.2, .infinity]
    #expect(DictationVoiceActivity.peak(of: withNaN) == 0.2)
    let none: [Float] = []
    #expect(DictationVoiceActivity.peak(of: none) == nil)
    let onlyNaN: [Float] = [.nan]
    #expect(DictationVoiceActivity.peak(of: onlyNaN) == nil)
}

@Test("Only Whisper Turbo is gated: Qwen3-ASR returned no text on any noise clip (F846)")
func voiceActivityGatesOnlyWhisper() {
    #expect(DictationVoiceActivity.gates(.whisperTurbo))
    #expect(!DictationVoiceActivity.gates(.qwenBalanced))
}
