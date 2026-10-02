import AVFoundation
import Foundation

/// Lengths of audio files, read through AVFoundation (F795).
enum DecodedAudio {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case let .unreadable(reason): return "The compressed audio could not be read back: \(reason)" }
        }
    }

    /// The length the container declares, without decoding. Nil when AVAudioFile cannot open it.
    static func declaredDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The length obtained by decoding every packet. A file whose header promises more than its
    /// packets deliver fails here, which is why Shrink checks this and not the header (design, step 4).
    static func fullyDecodedDuration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw Failure.unreadable("no decodable audio format")
        }
        var frames: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        return Double(frames) / format.sampleRate
    }
}
