import Foundation

/// Whether a Quick Dictation clip holds anything loud enough to be speech, decided from the audio
/// alone, before any model is asked (F599).
///
/// F449 gave the Whisper helper `transcribe()`'s own no-speech skip, and it never fires on the
/// shipped model: large-v3-turbo scores `no_speech_prob ≈ 0` on digital silence and on every
/// synthetic noise clip measured, and decodes "Thank you." from them. So a press with nothing said
/// pasted "Thank you." into the focused app. A model's own silence verdict cannot be the guard
/// when the model is what hallucinates; the level of the audio can be.
///
/// The measure is the RMS of the loudest 50 ms window. Not the whole clip's RMS, which a long hold
/// around one short word drags down; not the single loudest sample, which one click decides. A
/// clip is below the floor when even its loudest window is quieter than `floorDBFS`.
///
/// **What it cannot do.** It is a level, not a voice detector. Room noise louder than the floor —
/// a fan, a café, typing — passes it, and the model may still hallucinate on that; so may a key
/// click on an otherwise silent clip. The floor is set for the case it can decide without risk to
/// real speech: a silent or near-silent capture. The numbers behind it are in F599's log entry.
///
/// **Which way it fails.** Refusing a clip deletes the user's words, so everything here errs
/// towards transcribing: a clip it cannot read, or in a format it does not expect, is never called
/// silent, and the model decides as it did before.
public enum DictationSpeechFloor {
    /// 50 ms at the dictation recorder's rate.
    public static let windowSampleCount = DictationCaptureLimits.sampleRate / 20

    /// The loudest window must reach this, in dB relative to full scale, to be sent to a model.
    public static let floorDBFS: Double = -60

    public struct Level: Sendable, Equatable {
        /// RMS of the loudest `windowSampleCount`-sample window; `-infinity` for digital silence.
        public let loudestWindowDBFS: Double
        /// The largest absolute sample; `-infinity` for digital silence. Reported, not decided on.
        public let peakDBFS: Double

        public init(loudestWindowDBFS: Double, peakDBFS: Double) {
            self.loudestWindowDBFS = loudestWindowDBFS
            self.peakDBFS = peakDBFS
        }

        /// Whether nothing in the clip reaches the speech floor.
        public var isBelowFloor: Bool { loudestWindowDBFS < DictationSpeechFloor.floorDBFS }
    }

    /// The level of `samples` (full scale ±1), or nil when there are none. A clip shorter than one
    /// window is measured as one window.
    public static func level(of samples: [Float]) -> Level? {
        guard !samples.isEmpty else { return nil }
        var loudestMeanSquare = 0.0
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + windowSampleCount, samples.count)
            var sum = 0.0
            for index in start..<end {
                let sample = samples[index]
                sum += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }
            loudestMeanSquare = max(loudestMeanSquare, sum / Double(end - start))
            start = end
        }
        return Level(
            loudestWindowDBFS: 10 * log10(loudestMeanSquare),
            peakDBFS: 20 * log10(Double(peak))
        )
    }

    /// The level of a dictation clip on disk: 16-bit integer PCM, mono, as `WAVWriter` writes it.
    /// Nil for anything else, or anything unreadable — the caller then transcribes as before.
    public static func level(ofClipAt url: URL) -> Level? {
        guard let header = WAVInspection.header(at: url),
              header.formatTag == 1, header.channels == 1, header.bitsPerSample == 16,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The recorder caps a clip at `maximumSampleCount`; read no more than that, whatever the
        // header declares.
        let byteCount = min(header.declaredDataBytes, UInt64(DictationCaptureLimits.maximumSampleCount) * 2)
        guard (try? handle.seek(toOffset: UInt64(header.dataOffset))) != nil,
              let data = try? handle.read(upToCount: Int(clamping: byteCount)), data.count >= 2 else { return nil }
        let samples: [Float] = data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        return level(of: samples)
    }
}
