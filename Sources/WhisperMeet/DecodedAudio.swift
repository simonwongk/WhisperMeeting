import AVFoundation
import Foundation
import WhisperCore

/// Lengths, levels and tracks of audio files, read through AVFoundation (F795, F801).
enum DecodedAudio {
    enum Failure: LocalizedError {
        case unreadable(String)
        /// AVAudioFile opened the file and counts no frames in it (F1037): nothing it reads can be trusted, and asking
        /// where it stands raises.
        case uncounted
        var errorDescription: String? {
            switch self {
            case let .unreadable(reason): return "The compressed audio could not be read back: \(reason)"
            case .uncounted: return "The compressed audio could not be read back: its length is not counted."
            }
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

    /// What the container says each channel is — its channel layout, expanded to one Core Audio channel label per
    /// channel (`kAudioChannelLabel_Left` 1, `_Right` 2, `_Center` 3, `_LFEScreen` 4, …) — for Shrink's rule on
    /// what afconvert's mono mix keeps (F1001, review 2 of round 2, R2-A): afconvert mixes by these positions, in
    /// a CAF, an AIFF or a WAV alike, and leaves out a channel laid out as LFE. Nil when the file has no layout,
    /// or AVAudioFile cannot open it; an empty list when it has one that cannot be expanded to labels.
    static func channelLabels(of url: URL) -> [UInt32]? {
        guard let layout = (try? AVAudioFile(forReading: url))?.fileFormat.channelLayout else { return nil }
        return channelLabels(of: layout)
    }

    static func channelLabels(of layout: AVAudioChannelLayout) -> [UInt32] {
        let raw = layout.layout
        let tag = raw.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptionLabels(raw) }
        var size: UInt32 = 0
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            var bitmap = raw.pointee.mChannelBitmap
            let specifier = UInt32(MemoryLayout<AudioChannelBitmap>.size)
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap, specifier, &bitmap, &size) == noErr,
                  size >= UInt32(MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size) else { return [] }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { buffer.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForBitmap, specifier, &bitmap, &size, buffer) == noErr else { return [] }
            return descriptionLabels(UnsafePointer(buffer.assumingMemoryBound(to: AudioChannelLayout.self)))
        }
        var value = tag
        let specifier = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, specifier, &value, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size) else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { buffer.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, specifier, &value, &size, buffer) == noErr else { return [] }
        return descriptionLabels(UnsafePointer(buffer.assumingMemoryBound(to: AudioChannelLayout.self)))
    }

    /// The labels of a layout's channel descriptions, read past the one the struct declares.
    private static func descriptionLabels(_ layout: UnsafePointer<AudioChannelLayout>) -> [UInt32] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
        let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { first[$0].mChannelLabel }
    }

    /// The length the container declares, without decoding. Nil when AVAudioFile cannot open it.
    static func declaredDuration(of url: URL) -> TimeInterval? {
        // F1037: AVAudioFile opens an MP4 holding Opus and reports 0 frames, which is not a length — F911 took it for a
        // download holding nothing. A file it cannot count declares nothing, and is measured another way or kept.
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0, file.length > 0 else { return nil }
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
    ///
    /// F1037: `framePosition` is never asked. On an MP4 holding Opus AVAudioFile reports 0 frames and 0 frames a packet,
    /// and `framePosition` then *raises* an Objective-C exception ('prm?', from `CheckClientFormatSet`) that no Swift
    /// `catch` sees — `AVAudioFile.h` says nothing of it; measured on macOS 27 — while `read(into:)` reports the same
    /// failure as a thrown error. So the file's own length is probed first and a file of no frames refused here, before
    /// any read (`fullyDecodedEveryTrack` reads such a file with AVAssetReader, which reports through its status); and
    /// the loop counts the frames it read rather than asking where the file stands.
    static func fullyDecoded(of url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard format.sampleRate > 0, channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw Failure.unreadable("no decodable audio format")
        }
        let length = file.length
        guard length > 0 else { throw Failure.uncounted }
        var sums = WindowSums()
        var frames = 0
        while Int64(frames) < length {
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
    /// order. A file with one track (or none AVFoundation can list) is `fullyDecoded`, and one of those AVAudioFile counts
    /// no frames in (an MP4 holding Opus, F1037) is read with AVAssetReader like a recording of several tracks.
    static func fullyDecodedEveryTrack(of url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.count > 1 else {
            do {
                return try fullyDecoded(of: url)
            } catch Failure.uncounted {
                // F1037: a file AVAudioFile cannot count (an MP4 holding Opus) is read with AVAssetReader, as a
                // recording of several tracks is; with no track to read, it is unreadable.
                guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                    throw Failure.unreadable("no audio track to read")
                }
                return try await readerDecoded(asset: asset, tracks: [track])
            }
        }
        return try await readerDecoded(asset: asset, tracks: tracks)
    }

    /// `tracks` of `asset` decoded with AVAssetReader, each at its own rate and channel count, placed by presentation
    /// time; the body `fullyDecodedEveryTrack` has used for several tracks since F942.
    private static func readerDecoded(asset: AVAsset, tracks: [AVAssetTrack]) async throws -> Decoded {
        var sums = WindowSums()
        var firstChannel = 0
        // Where the audio ends: no buffer may be placed past it and a second, so a corrupt timestamp cannot
        // make this allocate windows in proportion to it, nor overflow a frame index (review of F942); and
        // the end itself no further than the audio the tracks hold allows, as the mixer's (second review).
        let audioEnd: TimeInterval
        do { audioEnd = try await RecordingMixer.boundedAudioEnd(of: tracks) } catch {
            throw Failure.unreadable(ErrorPresentation.readable(error))
        }
        for track in tracks {
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(ErrorPresentation.readable(error)) }
            // Float32, interleaved, at the track's own rate and channel count: no conversion asked for.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw Failure.unreadable("a track's audio cannot be decoded") }
            reader.add(output)
            guard reader.startReading() else {
                throw Failure.unreadable(reader.error.map { ErrorPresentation.readable($0) } ?? "the reader did not start")
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
                let limit = RecordingMixPlan.placementLimit(audioEnd: audioEnd, rate: format.mSampleRate)
                guard RecordingMixPlan.placement(firstFrame: start, frames: frames, laneStart: 0, laneCount: 0,
                                                 handed: 0, limit: limit) != nil else {
                    throw Failure.unreadable("a track is timed past the end of the recording's audio")
                }
                let count = channels
                sums.add(frames: frames, channelCount: count, firstChannel: firstChannel, rate: format.mSampleRate,
                         startFrame: start) { samples[$0 * count + $1] }
            }
            if reader.status == .failed {
                throw Failure.unreadable(reader.error.map { ErrorPresentation.readable($0) } ?? "a track could not be decoded")
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
