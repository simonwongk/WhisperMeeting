import Foundation

/// A captured raw float32 track and where its audio sat on the capture timeline.
public struct FloatTrack: Equatable, Sendable {
    public let url: URL
    /// The presentation timestamp of the track's first buffer, or nil if it never received one.
    public let firstPresentationTime: Double?
    public let frameCount: Int64

    public init(url: URL, firstPresentationTime: Double?, frameCount: Int64) {
        self.url = url
        self.firstPresentationTime = firstPresentationTime
        self.frameCount = frameCount
    }
}

public enum FloatTrackMixError: LocalizedError, Equatable {
    /// Neither track ever received a buffer, so there is no timeline to mix onto.
    case noAudioCaptured

    public var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return "No audio was captured on either track, so there was nothing to rebuild."
        }
    }
}

/// Mixes the microphone and system-audio tracks into the `meeting.wav` a recording is played and
/// transcribed from.
///
/// Moved out of `AudioCaptureEngine` by F278. It was `private` there, so the gain rule below and the
/// header ordering — both load-bearing, neither obvious — ran on every meeting with no test. Nothing
/// here needs AVFoundation or CoreMedia; it is file I/O and arithmetic, and it belongs somewhere a
/// test can reach it.
public enum FloatTrackMixer {
    /// Frames per read. Also the interval at which an off-by-one would put a click in a recording.
    static let chunkFrames = 8_192

    /// Gain applied to the sum while it fits. Nearly unity on purpose: one side talking at a time
    /// is the common case in a meeting, and halving it there would make every recording quiet.
    static let soloGain: Float = 0.95

    /// Where the curve stops being exactly linear, in units of `|system + microphone|`.
    ///
    /// Forced from both sides rather than chosen. A float32 track is nominally within [-1, 1], so a
    /// *lone* track's `|sum|` never exceeds 1.0 and the knee must be at least 1.0 or a loud solo
    /// passage would be distorted. And `soloGain * |sum|` must stay below 1.0 to leave the limiter
    /// anywhere to work, which needs `|sum| < 1/0.95 = 1.0526`. 1.0 is the only round number in
    /// that window.
    static let linearSumLimit: Float = 1.0

    /// What is left between the knee's output and full scale — the room the limiter has. About
    /// 0.05; not exactly, because `Double(Float(0.95))` is 0.949999988079071.
    static let limiterHeadroom = 1.0 - Double(soloGain) * Double(linearSumLimit)

    /// Sums one frame of the two tracks into a clamped 16-bit sample.
    ///
    /// The one copy of the gain rule (F278). It existed twice — here and in
    /// `InterruptedRecordingRecovery`'s rebuild — with the constants written out longhand in both.
    /// These numbers are a judgement about how two microphones sum, and a judgement kept in two
    /// places drifts; the drift would be audible only in the rebuild path, where nobody has the
    /// original recording to compare against.
    ///
    /// **Why this is a curve and not a choice between two gains (F345).** It used to pick `0.5`
    /// when both tracks exceeded an activity floor and `0.95` otherwise, decided from the
    /// *instantaneous* sample. A microphone waveform crosses that floor twice per cycle, so the
    /// system track was multiplied by a square wave at roughly twice the microphone's dominant
    /// frequency: amplitude modulation, measured on synthetic signals at **−14.9 dBc** of injected
    /// sidebands against a −103 dBc quantization floor, and reported on real captures as a buzz.
    /// The failure is better stated in the time domain — a **one-LSB change in the input moved the
    /// output by up to 3,096 LSB**, because the gain could change by 0.45 between adjacent samples.
    ///
    /// So the gain stopped being a two-valued choice. Below the knee the output is exactly
    /// `soloGain * (system + microphone)` — bit-identical to an ideal linear mix, with no modulator
    /// left to make sidebands. Above it, an odd, monotone, `C¹`-continuous soft limiter that
    /// asymptotes *below* full scale, which is what now prevents the clipping the old `0.5` branch
    /// existed to prevent: `0.8 + 0.6` peaks at 32,576 rather than clipping 17% of its frames.
    ///
    /// **It is deliberately memoryless.** An envelope follower or a smoothed gain would need state,
    /// and state here has to survive `chunkFrames` boundaries *and* stay identical between this
    /// path and the recovery rebuild, whose `chunkSize` is a parameter (8,192 in production, 100 in
    /// `RecoveryTruncationTests`). Both stateful designs were measured and both were worse: an
    /// envelope shifts the effective floor by the signal's crest factor, and a smoothed gain cannot
    /// outrun the sum, so it clips where this does not. A pure function of one frame keeps chunking
    /// free — mixing at chunk sizes 1, 100 and 8,192 is byte-identical — and keeps
    /// `InterruptedRecordingRecovery` unchanged.
    ///
    /// Clamped before conversion, because `Int16(1.4 * 32767)` traps and a wrapped sum would flip
    /// sign — a loud click where the honest failure is a quiet clip. The clamp is now unreachable
    /// for finite input (the curve's own ceiling is below 1.0) and is kept for NaN, which reaches
    /// `min(1, nan) == 1.0` and so still produces full scale rather than trapping.
    public static func mixedSample(system: Float, microphone: Float) -> Int16 {
        let sum = system + microphone
        let magnitude = abs(sum)
        let shaped: Float
        if magnitude <= linearSumLimit {
            shaped = soloGain * magnitude
        } else {
            // `1 - h/(1 + e)` with `e` rising linearly past the knee: equal to `soloGain * |sum|`
            // and to its slope at the knee, monotone after it, and bounded above by 1.
            let excess = Double(soloGain) * (Double(magnitude) - Double(linearSumLimit)) / limiterHeadroom
            shaped = Float(1.0 - limiterHeadroom / (1 + excess))
        }
        let mixed = sum < 0 ? -shaped : shaped
        return Int16(clampedAudioSample: mixed)
    }

    /// Writes `system` and `microphone` to `outputURL` as 16-bit mono PCM, returning its duration.
    ///
    /// Tracks are aligned by presentation timestamp: whichever started later is zero-padded at the
    /// front, so a late-starting microphone stays in sync instead of sliding earlier in the mix.
    public static func mix(
        system: FloatTrack,
        microphone: FloatTrack,
        sampleRate: Double,
        outputURL: URL,
        classicDataLimit: UInt64 = WAVWriter.classicDataLimit
    ) throws -> TimeInterval {
        let starts = [system.firstPresentationTime, microphone.firstPresentationTime].compactMap { $0 }
        guard let earliestStart = starts.min() else {
            throw FloatTrackMixError.noAudioCaptured
        }
        let systemPadding = paddingFrames(
            firstPresentationTime: system.firstPresentationTime,
            earliestStart: earliestStart,
            sampleRate: sampleRate
        )
        let microphonePadding = paddingFrames(
            firstPresentationTime: microphone.firstPresentationTime,
            earliestStart: earliestStart,
            sampleRate: sampleRate
        )
        let totalFrames = max(
            systemPadding + system.frameCount,
            microphonePadding + microphone.frameCount
        )

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        // The header goes in LAST, over these reserved zero bytes (44, or 80 when the mix is long
        // enough to need RF64 — known now, because `totalFrames` is: F302). That ordering is what makes a
        // truncated `meeting.wav` detectable: a file cut short keeps a zeroed header, which fails
        // `wavDuration`, so recovery falls back to the `.f32` tracks rather than trusting a short
        // file whose header claims it is complete.
        let headerLength = WAVWriter.headerLength(
            dataByteCount: UInt64(max(0, totalFrames)) * 2, classicDataLimit: classicDataLimit
        )
        try ThrowingFileHandleIO.write(Data(repeating: 0, count: headerLength), to: output)

        let systemReader = try PaddedFloatReader(url: system.url, paddingFrames: systemPadding)
        let microphoneReader = try PaddedFloatReader(
            url: microphone.url,
            paddingFrames: microphonePadding
        )
        var writtenFrames: Int64 = 0

        while writtenFrames < totalFrames {
            let count = min(Int64(chunkFrames), totalFrames - writtenFrames)
            let systemSamples = systemReader.read(frameCount: Int(count))
            let microphoneSamples = microphoneReader.read(frameCount: Int(count))
            var pcm = [Int16](repeating: 0, count: Int(count))
            for index in pcm.indices {
                pcm[index] = mixedSample(
                    system: systemSamples[index],
                    microphone: microphoneSamples[index]
                )
            }
            try pcm.withUnsafeBytes {
                try ThrowingFileHandleIO.write(Data($0), to: output)
            }
            writtenFrames += count
        }

        try output.seek(toOffset: 0)
        try ThrowingFileHandleIO.write(
            // `sampleRate` is a `Double` parameter, so an absurd caller traps here — during
            // `stop()`, which is the most expensive moment available.
            WAVWriter.header(
                sampleRate: UInt32(saturating: sampleRate),
                dataByteCount64: UInt64(max(0, writtenFrames)) * 2,
                classicDataLimit: classicDataLimit
            ),
            to: output
        )
        return Double(writtenFrames) / sampleRate
    }

    private static func paddingFrames(
        firstPresentationTime: Double?,
        earliestStart: Double,
        sampleRate: Double
    ) -> Int64 {
        guard let firstPresentationTime else { return 0 }
        // `Int64(Double)` TRAPS on overflow in Swift, and this runs during `stop()` — so a
        // presentation timestamp the capture recorded badly would lose the entire meeting at the
        // moment it is being saved, which is worse than any wrong duration. The mixer takes
        // whatever timestamps it is given, and F151 established those are not to be trusted to be
        // sane.
        //
        // Pre-existing: F278 moved this function here from `AudioCaptureEngine` without looking at
        // it. Found on the third pass of one self-review, after `CaptureGapPolicy` and
        // `CaptureRestartPolicy`.
        let frames = CaptureRestartPolicy.saturatingFrames(
            (firstPresentationTime - earliestStart) * sampleRate
        )
        // **A timestamp implying absurd padding carries no usable alignment, so it is treated as
        // absent** — which is already a case this function handles, returning 0. Saturating alone
        // was not enough: `Int64.max` padding then overflowed `systemPadding + frameCount` on the
        // next line and trapped there instead, one line further from the cause.
        //
        // The bound is 24 hours, chosen to be unambiguously nonsense rather than to be a policy: a
        // WAV's `UInt32` data size runs out at ~12.4 h (F150), so any real recording is well under
        // it and nothing legitimate is being discarded.
        return frames > maximumPaddingFrames ? 0 : frames
    }

    /// Padding beyond which a presentation timestamp is nonsense rather than an offset.
    static let maximumPaddingFrames = Int64(48_000) * 60 * 60 * 24
}

/// Reads a raw float32 track, presenting `paddingFrames` of leading silence first.
private final class PaddedFloatReader {
    private let handle: FileHandle
    private var paddingFrames: Int64

    init(url: URL, paddingFrames: Int64) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.paddingFrames = paddingFrames
    }

    deinit {
        try? handle.close()
    }

    /// Always returns `frameCount` samples — short reads and end-of-file read as silence, which is
    /// what lets a ragged pair of tracks mix without a special case.
    func read(frameCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        var destinationIndex = 0
        if paddingFrames > 0 {
            let silenceCount = min(Int64(frameCount), paddingFrames)
            paddingFrames -= silenceCount
            destinationIndex += Int(silenceCount)
        }
        guard destinationIndex < frameCount else { return result }

        let requestedBytes = (frameCount - destinationIndex) * MemoryLayout<Float>.size
        guard let data = try? handle.read(upToCount: requestedBytes), !data.isEmpty else {
            return result
        }
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            for index in 0..<source.count {
                result[destinationIndex + index] = source[index]
            }
        }
        return result
    }
}
