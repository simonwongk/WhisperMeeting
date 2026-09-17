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

public enum FloatTrackMixError: Error, Equatable {
    /// Neither track ever received a buffer, so there is no timeline to mix onto.
    case noAudioCaptured
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

    /// Below this magnitude a sample counts as silence for the gain rule.
    static let activityFloor: Float = 0.01

    /// Gain when both tracks carry audio — summing two active tracks at unity would clip.
    static let overlappingGain: Float = 0.5

    /// Gain when only one track carries audio. Nearly unity on purpose: one side talking at a time
    /// is the common case in a meeting, and halving it there would make every recording quiet.
    static let soloGain: Float = 0.95

    /// Sums one frame of the two tracks into a clamped 16-bit sample.
    ///
    /// The one copy of the gain rule (F278). It existed twice — here and in
    /// `InterruptedRecordingRecovery`'s rebuild — with the constants written out longhand in both.
    /// These numbers are a judgement about how two microphones sum, and a judgement kept in two
    /// places drifts; the drift would be audible only in the rebuild path, where nobody has the
    /// original recording to compare against.
    ///
    /// Clamped before conversion, because `Int16(1.4 * 32767)` traps and a wrapped sum would flip
    /// sign — a loud click where the honest failure is a quiet clip.
    public static func mixedSample(system: Float, microphone: Float) -> Int16 {
        let bothActive = abs(system) > activityFloor && abs(microphone) > activityFloor
        let mixed = (system + microphone) * (bothActive ? overlappingGain : soloGain)
        return Int16(max(-1, min(1, mixed)) * Float(Int16.max))
    }

    /// Writes `system` and `microphone` to `outputURL` as 16-bit mono PCM, returning its duration.
    ///
    /// Tracks are aligned by presentation timestamp: whichever started later is zero-padded at the
    /// front, so a late-starting microphone stays in sync instead of sliding earlier in the mix.
    public static func mix(
        system: FloatTrack,
        microphone: FloatTrack,
        sampleRate: Double,
        outputURL: URL
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
        // The header goes in LAST, over these 44 reserved zero bytes. That ordering is what makes a
        // truncated `meeting.wav` detectable: a file cut short keeps a zeroed header, which fails
        // `wavDuration`, so recovery falls back to the `.f32` tracks rather than trusting a short
        // file whose header claims it is complete.
        try ThrowingFileHandleIO.write(Data(repeating: 0, count: 44), to: output)

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

        let dataByteCount = UInt32(clamping: writtenFrames * 2)
        try output.seek(toOffset: 0)
        try ThrowingFileHandleIO.write(
            WAVWriter.header(sampleRate: UInt32(sampleRate), dataByteCount: dataByteCount),
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
        return max(0, Int64((firstPresentationTime - earliestStart) * sampleRate))
    }
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
