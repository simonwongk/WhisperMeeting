import AVFoundation
import Foundation
import WhisperCore

/// Lengths, levels and tracks of audio files, read through AVFoundation (F795, F801).
enum DecodedAudio {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case let .unreadable(reason): return "The compressed audio could not be read back: \(reason)" }
        }
    }

    /// What decoding every packet of a file found (F801): its length, and its level — the RMS over
    /// every channel's samples, on the same 0…1 scale for every format. That is the sound in the file
    /// before any mixing. It used to be the RMS of the channels' per-frame mean, the mono mix Shrink's
    /// encode makes (`--mix`, F796); measured that way, a stereo recording whose channels cancel in
    /// the mix read as silence on both sides of the comparison, and Shrink deleted it for a silent
    /// copy (F801 review). A mono file reads the same either way.
    struct Decoded: Equatable, Sendable {
        var duration: TimeInterval
        var level: Double
        /// The same level over each `MeetingStoragePlan.levelWindowSeconds` of the file in turn, the
        /// last window as long as what is left (F801 review: a copy can keep the whole file's level
        /// within the band and still have lost a stretch of the recording). Empty when not measured.
        var windowLevels: [Double] = []
    }

    /// The length the container declares, without decoding. Nil when AVAudioFile cannot open it.
    static func declaredDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The length obtained by decoding every packet. A file whose header promises more than its
    /// packets deliver fails here, which is why Shrink checks this and not the header (design, step 4).
    static func fullyDecodedDuration(of url: URL) throws -> TimeInterval {
        try fullyDecoded(of: url).duration
    }

    /// Decodes every packet, once, for the length, the level and the level of each window (F801).
    /// Shrink decodes the compressed copy this way, and the original too, so the levels it compares
    /// come from the same reader.
    static func fullyDecoded(of url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard format.sampleRate > 0, channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw Failure.unreadable("no decodable audio format")
        }
        let framesPerWindow = Swift.max(1, Int(saturating: MeetingStoragePlan.levelWindowSeconds * format.sampleRate))
        var frames: AVAudioFramePosition = 0
        var sumOfSquares = 0.0
        var windowSum = 0.0, windowFrames = 0
        var windowLevels: [Double] = []
        func closeWindow() {
            windowLevels.append((windowSum / (Double(windowFrames) * Double(channels))).squareRoot())
            windowSum = 0
            windowFrames = 0
        }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            // AVAudioFile's processing format is always deinterleaved Float32, so this is present.
            if let samples = buffer.floatChannelData {
                for frame in 0..<count {
                    var squares = 0.0
                    for channel in 0..<channels {
                        let value = Double(samples[channel][frame])
                        squares += value * value
                    }
                    sumOfSquares += squares
                    windowSum += squares
                    windowFrames += 1
                    if windowFrames == framesPerWindow { closeWindow() }
                }
            }
            frames += AVAudioFramePosition(count)
        }
        if windowFrames > 0 { closeWindow() }
        let sampleCount = Double(frames) * Double(channels)
        let level = sampleCount > 0 ? (sumOfSquares / sampleCount).squareRoot() : 0
        return Decoded(duration: Double(frames) / format.sampleRate, level: level, windowLevels: windowLevels)
    }

    /// How many audio tracks the container holds, or nil when AVFoundation cannot read it (F801).
    /// Each decoder the app uses reads one of them: measured on synthetic two-track files, afconvert
    /// and AVAudioFile kept only the first track of a `.mov`, an `.mp4` and an `.m4a`, and Whisper's
    /// ffmpeg decode only the first of the `.mov`.
    static func audioTrackCount(of url: URL) async -> Int? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else { return nil }
        return tracks.count
    }
}
