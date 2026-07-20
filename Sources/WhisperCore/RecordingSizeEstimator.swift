import Foundation

/// Predicts how large a recording is becoming while it is still in progress, using constant
/// bitrate arithmetic from elapsed time. No disk access — the capture format is fixed, so byte
/// counts are exact functions of duration.
///
/// The layout on disk (see `AudioCaptureEngine`):
/// - `meeting.wav`: 16-bit signed mono PCM at the target sample rate — the deliverable.
/// - two float32 mono source tracks (`system-audio.f32`, `microphone-audio.f32`) written live
///   during capture and retained afterwards for a possible future diarization step.
public enum RecordingSizeEstimator {
    /// Matches `AudioCaptureEngine.targetSampleRate`.
    public static let defaultSampleRate: Double = 48_000

    /// Bytes per second of the final mixed `meeting.wav` (mono, 16-bit).
    public static func mixedBytesPerSecond(sampleRate: Double = defaultSampleRate) -> Int64 {
        Int64(sampleRate.rounded()) * 2
    }

    /// Bytes per second written for both float32 source tracks combined (mono, 4 bytes/sample).
    public static func sourceBytesPerSecond(sampleRate: Double = defaultSampleRate) -> Int64 {
        Int64(sampleRate.rounded()) * 4 * 2
    }

    /// Estimated size of the final `meeting.wav` for a recording of the given duration.
    public static func mixedBytes(
        forDuration seconds: TimeInterval,
        sampleRate: Double = defaultSampleRate
    ) -> Int64 {
        bytes(seconds, mixedBytesPerSecond(sampleRate: sampleRate))
    }

    /// Estimated total on-disk footprint of the recording folder while capturing: the live
    /// float32 source tracks plus the mixed WAV that is produced when the meeting ends.
    public static func workingBytes(
        forDuration seconds: TimeInterval,
        sampleRate: Double = defaultSampleRate
    ) -> Int64 {
        bytes(
            seconds,
            mixedBytesPerSecond(sampleRate: sampleRate)
                + sourceBytesPerSecond(sampleRate: sampleRate)
        )
    }

    private static func bytes(_ seconds: TimeInterval, _ perSecond: Int64) -> Int64 {
        guard seconds > 0 else { return 0 }
        return Int64((Double(perSecond) * seconds).rounded())
    }
}
