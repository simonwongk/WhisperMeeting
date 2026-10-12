import AVFoundation
import Foundation
import WhisperCore

/// Mixes every channel of every audio track of a recording into one 16 kHz mono 16-bit WAV (F942), for
/// the engines, speaker analysis and Shrink. `RecordingMixPlan` decides when; this reads and writes.
///
/// **How it reads.** One `AVAssetReader` with an `AVAssetReaderTrackOutput` per audio track, each asked
/// for 32-bit float at 16 kHz with the track's own channel count, and for more than two channels a
/// discrete layout, so that no channel is downmixed or dropped on the way: measured on 4-, 6- and
/// 8-channel WAVs with no layout, with extensible mask 0 and with 5.1 positions, every channel comes back
/// on its own at its own level. A mono downmix asked of AVFoundation, by contrast, keeps only channel 1 of
/// a WAV with no layout at 3, 4, 6 and 8 channels (both probes are in F942's log entry). Each
/// track's buffers are placed on the recording's timeline by their presentation time, so a track that
/// starts later is heard when it starts, and the tracks are read in step so memory stays bounded.
///
/// **How it sums.** Every channel of every track is added as it is, and the sum goes through
/// `FloatTrackMixer.limitedSample`, the rule that mixes a capture's microphone and system audio (F345):
/// 0.95 of the sum while it fits, a smooth limiter above that never reaches full scale. So a voice alone
/// on its track keeps nearly its recorded level — the case of a call recorded a side per track, where
/// dividing by the number of tracks would make every voice quieter — and no sum clips. One pass,
/// memoryless, so it needs no peak found first.
///
/// The recording is only read; the mix is written where the caller says.
enum RecordingMixer {
    static let sampleRate = 16_000

    struct Result: Equatable, Sendable {
        /// How many tracks, and how many channels in all, were summed.
        var tracks: Int
        var channels: Int
        /// The mix's length, from the frames written.
        var duration: TimeInterval
    }

    enum Failure: LocalizedError, Equatable {
        case notMixable(RecordingMixPlan.Refusal)
        case unreadable(String)
        case shortDecode(expected: TimeInterval, decoded: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notMixable(.alternateTracks):
                return "This recording's audio tracks are alternatives to each other, so they are not mixed into one."
            case .notMixable(.unreadableTrack), .unreadable:
                return "This recording's audio tracks could not be read to mix them into one."
            case let .shortDecode(expected, decoded):
                return "Mixing this recording's audio tracks stopped at \(TranscriptFormatter.clock(decoded)) of \(TranscriptFormatter.clock(expected))."
            }
        }
    }

    /// What each audio track of `url` holds, or nil when AVFoundation cannot read it.
    static func tracks(of url: URL) async -> [RecordingMixPlan.Track]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        return await facts(of: tracks, in: asset)
    }

    /// What each of these audio tracks of `asset` holds, in the same order.
    private static func facts(of tracks: [AVAssetTrack], in asset: AVAsset) async -> [RecordingMixPlan.Track] {
        let groups = (try? await asset.load(.trackGroups)) ?? []
        var facts: [RecordingMixPlan.Track] = []
        for track in tracks {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let channels = descriptions.compactMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
            }.map(Int.init).max() ?? 0
            let group = groups.firstIndex { $0.trackIDs.contains(NSNumber(value: track.trackID)) }
            facts.append(.init(channels: channels, alternateGroup: group))
        }
        return facts
    }

    /// The plan for `url`: `asItIs` for a WAV whose header says one or two channels (a WAV holds one
    /// track, so this skips AVFoundation for every capture), and for anything AVFoundation cannot read,
    /// which the engines then decode as they always have.
    static func decision(for url: URL) async -> RecordingMixPlan.Decision {
        if let header = WAVInspection.header(at: url), header.channels <= 2 { return .asItIs }
        guard let tracks = await tracks(of: url) else { return .asItIs }
        return RecordingMixPlan.decision(for: tracks)
    }

    /// The file the engines and speaker analysis should hear for `url`: the mix, written into
    /// `directory`, when the recording needs one, else nil and the recording is used as it is.
    /// Alternate tracks are not mixed (the engines keep decoding the default one); a recording whose
    /// tracks cannot be read is handed on as it is too.
    static func mixIfNeeded(_ url: URL, into directory: URL) async throws -> URL? {
        guard case .mixEveryChannel = await decision(for: url) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("mixed.wav")
        _ = try await mixEveryChannel(of: url, to: output)
        return output
    }

    /// Where the recording's audio ends: the latest end of its audio tracks' own time ranges. Not the
    /// asset's duration, which counts a video track too: a movie whose picture runs past its sound is a
    /// whole recording, and measured against the picture its mix "stopped short" on every engine run
    /// (review of F942, R1).
    static func audioEnd(of tracks: [AVAssetTrack]) async throws -> TimeInterval {
        var end = 0.0
        for track in tracks {
            let seconds = try await track.load(.timeRange).end.seconds
            if seconds.isFinite { end = Swift.max(end, seconds) }
        }
        return end
    }

    /// Mixes every channel of every audio track of `input` into a 16 kHz mono 16-bit WAV at `output`.
    /// Throws for alternate tracks, an unreadable file, or a decode that stops more than half a second
    /// short of where the audio tracks end; `output` is then removed.
    static func mixEveryChannel(of input: URL, to output: URL) async throws -> Result {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        let facts: [RecordingMixPlan.Track]
        let declared: TimeInterval
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            declared = try await audioEnd(of: tracks)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        facts = await Self.facts(of: tracks, in: asset)
        if case let .unsupported(refusal) = RecordingMixPlan.decision(for: facts) { throw Failure.notMixable(refusal) }
        guard !tracks.isEmpty else { throw Failure.unreadable("no audio tracks") }
        do {
            let frames = try write(tracks: tracks, channels: facts.map(\.channels), asset: asset,
                                   expectedSeconds: declared, to: output)
            let duration = Double(frames) / Double(sampleRate)
            if declared.isFinite, declared - duration > 0.5 {
                throw Failure.shortDecode(expected: declared, decoded: duration)
            }
            return Result(tracks: tracks.count, channels: facts.reduce(0) { $0 + $1.channels }, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// One track being read: its output, its channel count, and the mono sum of its channels that has
    /// been read but not yet written, starting at frame `start` of the timeline.
    private struct Lane {
        let output: AVAssetReaderTrackOutput
        let channels: Int
        var pending: [Float] = []
        var start = 0
        var finished = false
        var end: Int { start + pending.count }
    }

    /// Reads every track in step and writes their sum; returns the frames written.
    private static func write(tracks: [AVAssetTrack], channels: [Int], asset: AVAsset,
                              expectedSeconds: TimeInterval, to output: URL) throws -> Int {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }
        var lanes: [Lane] = []
        for (track, count) in zip(tracks, channels) {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: count,
            ]
            if count > 2 {
                // Discrete, so each channel stays apart through the conversion: asked for fewer, or
                // for positions, AVFoundation would downmix, and of a WAV with no layout keep channel 1.
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count)
                settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            trackOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(trackOutput) else { throw Failure.unreadable("a track's audio cannot be decoded") }
            reader.add(trackOutput)
            lanes.append(Lane(output: trackOutput, channels: count))
        }
        guard reader.startReading() else {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "the reader did not start")
        }
        defer { reader.cancelReading() }

        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: output) } catch { throw Failure.unreadable(error.localizedDescription) }
        defer { try? handle.close() }
        // The header is written last, when the length is known, over room reserved first: the classic
        // 44 bytes every reader takes, unless the recording's declared length (with a tenth to spare)
        // could need RF64, past about 37 hours at 16 kHz (F302's rule, as the recovery rebuild applies it).
        let seconds = expectedSeconds.isFinite ? Swift.max(0, expectedSeconds) : 0
        let estimate = UInt64(clamping: Int64(saturating: seconds * 1.1 * Double(sampleRate) * 2))
        let rf64 = WAVWriter.headerLength(dataByteCount: estimate) == 80
        try handle.write(contentsOf: Data(count: rf64 ? 80 : 44))
        var written = 0

        func pull(_ index: Int) throws {
            guard let buffer = lanes[index].output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw Failure.unreadable(reader.error?.localizedDescription ?? "a track could not be decoded")
                }
                lanes[index].finished = true
                return
            }
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            let count = lanes[index].channels
            var interleaved = [Float](repeating: 0, count: frames * count)
            let copied = interleaved.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { throw Failure.unreadable("a buffer could not be read") }
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<count { sum += interleaved[frame * count + channel] }
                mono[frame] = sum
            }
            // Its place on the timeline. A gap before it is silence; frames at or before what is already
            // placed — an overlap, which a well-formed track does not have, or a stretch already written
            // — are dropped, so what was placed first stands.
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            let first = time.isNumeric ? Int(saturating: (time.seconds * Double(sampleRate)).rounded()) : lanes[index].end
            if lanes[index].pending.isEmpty, lanes[index].end < written { lanes[index].start = written }
            let end = lanes[index].end
            if first > end {
                lanes[index].pending.append(contentsOf: [Float](repeating: 0, count: first - end))
                lanes[index].pending.append(contentsOf: mono)
            } else if end - first < mono.count {
                lanes[index].pending.append(contentsOf: mono[(end - first)...])
            }
        }

        while true {
            for index in lanes.indices where !lanes[index].finished && lanes[index].end <= written {
                try pull(index)
            }
            let live = lanes.filter { !$0.finished }
            let limit = live.isEmpty ? (lanes.map(\.end).max() ?? written) : (live.map(\.end).min() ?? written)
            if limit > written {
                var block = Data(count: (limit - written) * 2)
                block.withUnsafeMutableBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for offset in 0..<(limit - written) {
                        let frame = written + offset
                        var sum: Float = 0
                        for lane in lanes where frame >= lane.start && frame < lane.end { sum += lane.pending[frame - lane.start] }
                        samples[offset] = FloatTrackMixer.limitedSample(sum: sum).littleEndian
                    }
                }
                try handle.write(contentsOf: block)
                written = limit
                for index in lanes.indices where lanes[index].start < written {
                    let drop = Swift.min(lanes[index].pending.count, written - lanes[index].start)
                    lanes[index].pending.removeFirst(drop)
                    lanes[index].start += drop
                }
            }
            if live.isEmpty { break }
        }
        let bytes = UInt64(written) * 2
        guard rf64 || bytes <= WAVWriter.classicDataLimit else {
            throw Failure.unreadable("the mix ran far past the recording's declared length")
        }
        let header = WAVWriter.header(sampleRate: UInt32(sampleRate), dataByteCount64: bytes, forceRF64: rf64)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        return written
    }
}
