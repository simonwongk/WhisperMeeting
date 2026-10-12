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
        /// The same, for each channel of each track by itself, the tracks in order (F942): a mixed copy
        /// is checked against every one of them. Empty when not measured.
        var channelWindowLevels: [[Double]] = []
    }

    /// Running sums of squares per `MeetingStoragePlan.levelWindowSeconds` window, over all channels and
    /// for each channel, for one or more tracks placed on one timeline by time (F942).
    private struct WindowSums {
        var total = 0.0
        var samples = 0.0
        var windows: [(squares: Double, samples: Double)] = []
        var channels: [[Double]] = []
        var channelFrames: [[Double]] = []
        var end: TimeInterval = 0

        /// Adds `frames` frames of `channelCount` channels whose first frame is frame `startFrame` of the
        /// timeline at `rate`; `value(frame, channel)` reads one sample. The channels are numbered from
        /// `firstChannel` among every track's.
        mutating func add(frames: Int, channelCount: Int, firstChannel: Int, rate: Double, startFrame: Int,
                          value: (Int, Int) -> Float) {
            while channels.count < firstChannel + channelCount { channels.append([]); channelFrames.append([]) }
            let perWindow = Swift.max(1, Int(saturating: MeetingStoragePlan.levelWindowSeconds * rate))
            for frame in 0..<frames {
                let window = Swift.max(0, startFrame + frame) / perWindow
                if windows.count <= window { windows.append(contentsOf: repeatElement((squares: 0.0, samples: 0.0), count: window + 1 - windows.count)) }
                var squares = 0.0
                for channel in 0..<channelCount {
                    let sample = Double(value(frame, channel))
                    let square = sample * sample
                    squares += square
                    let index = firstChannel + channel
                    if channels[index].count <= window {
                        channels[index].append(contentsOf: repeatElement(0, count: window + 1 - channels[index].count))
                        channelFrames[index].append(contentsOf: repeatElement(0, count: window + 1 - channelFrames[index].count))
                    }
                    channels[index][window] += square
                    channelFrames[index][window] += 1
                }
                windows[window].squares += squares
                windows[window].samples += Double(channelCount)
                total += squares
                self.samples += Double(channelCount)
            }
            end = Swift.max(end, Double(startFrame + frames) / rate)
        }

        var decoded: Decoded {
            func rms(_ squares: Double, _ count: Double) -> Double { count > 0 ? (squares / count).squareRoot() : 0 }
            return Decoded(
                duration: end, level: rms(total, samples),
                windowLevels: windows.map { rms($0.squares, $0.samples) },
                channelWindowLevels: zip(channels, channelFrames).map { squares, frames in
                    zip(squares, frames).map { rms($0, $1) }
                })
        }
    }

    /// How many channels the file holds, from its header, or nil when AVAudioFile cannot open it (F801
    /// review). More than two are mixed into Shrink's copy by `RecordingMixer` (F942), because the
    /// encode's own mono mix keeps channel 1 alone of a file with more than two channels and no layout.
    static func channelCount(of url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Int(file.fileFormat.channelCount)
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
        var sums = WindowSums()
        var frames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            // AVAudioFile's processing format is always deinterleaved Float32, so this is present.
            if let samples = buffer.floatChannelData {
                sums.add(frames: count, channelCount: channels, firstChannel: 0, rate: format.sampleRate,
                         startFrame: frames) { samples[$1][$0] }
            }
            frames += count
        }
        var decoded = sums.decoded
        decoded.duration = Double(frames) / format.sampleRate
        return decoded
    }

    /// `fullyDecoded`, over every audio track of a container with several (F942). AVAudioFile reads the
    /// first track only, so a recording with more is read track by track with AVAssetReader, each at its
    /// own rate and channel count — nothing is mixed or converted before it is measured — and placed on
    /// the recording's timeline by its presentation time. The level and windows are then over every
    /// channel of every track, and `channelWindowLevels` lists each of those channels, the tracks in
    /// order. A file with one track (or none AVFoundation can list) is `fullyDecoded`.
    static func fullyDecodedEveryTrack(of url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.count > 1 else {
            return try fullyDecoded(of: url)
        }
        var sums = WindowSums()
        var firstChannel = 0
        for track in tracks {
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }
            // Float32, interleaved, at the track's own rate and channel count: no conversion asked for.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw Failure.unreadable("a track's audio cannot be decoded") }
            reader.add(output)
            guard reader.startReading() else {
                throw Failure.unreadable(reader.error?.localizedDescription ?? "the reader did not start")
            }
            var channels = 0
            while let buffer = output.copyNextSampleBuffer() {
                let frames = CMSampleBufferGetNumSamples(buffer)
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer),
                      let description = CMSampleBufferGetFormatDescription(buffer),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { continue }
                channels = Int(format.mChannelsPerFrame)
                var samples = [Float](repeating: 0, count: frames * channels)
                let copied = samples.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                guard copied == kCMBlockBufferNoErr else { throw Failure.unreadable("a buffer could not be read") }
                let time = CMSampleBufferGetPresentationTimeStamp(buffer)
                let start = time.isNumeric ? Int(saturating: (time.seconds * format.mSampleRate).rounded()) : 0
                let count = channels
                sums.add(frames: frames, channelCount: count, firstChannel: firstChannel, rate: format.mSampleRate,
                         startFrame: start) { samples[$0 * count + $1] }
            }
            if reader.status == .failed {
                throw Failure.unreadable(reader.error?.localizedDescription ?? "a track could not be decoded")
            }
            firstChannel += channels
        }
        return sums.decoded
    }

    /// How many audio tracks the container holds, or nil when AVFoundation cannot read it (F801).
    /// Each decoder the app hands a recording to reads one of them: measured on synthetic two-track
    /// files, afconvert and AVAudioFile kept only the first track of a `.mov`, an `.mp4` and an `.m4a`,
    /// and Whisper's ffmpeg decode only the first of each. So such a recording is mixed first (F942).
    static func audioTrackCount(of url: URL) async -> Int? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else { return nil }
        return tracks.count
    }
}
