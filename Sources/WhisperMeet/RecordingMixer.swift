import AVFoundation
import Foundation
import WhisperCore

/// Mixes every channel of every audio track of a recording into one 16 kHz mono 16-bit WAV (F942), for
/// the engines, speaker analysis and Shrink, and measures a mono copy against the tracks it was made from
/// (`audit`), so Shrink deletes nothing a mix or an encode lost. `RecordingMixPlan` decides when, combines
/// a track's channels (`channelWeight`) and judges the measurement; this reads and writes.
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
/// **How it mixes.** A capture's rule, so an import with several tracks is heard as a capture is: each
/// track's channels are averaged into that track's own signal (`RecordingMixPlan.channelWeight`), as a
/// capture averages a microphone's channels (F659), and the tracks' signals are summed through
/// `FloatTrackMixer.limitedSample`, as a capture sums its microphone and system audio (F345): 0.95 of the
/// sum while it fits, a smooth limiter above that never reaches full scale. So a voice alone on its track
/// keeps nearly its recorded level — the case of a call recorded a side per track, where dividing by the
/// number of tracks would make every voice quieter — no sum clips, and a stereo track is no louder beside
/// another track than alone (review of F942). One pass, memoryless, so it needs no peak found first.
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
                return "This recording's audio tracks are in different languages, alternatives to each other, so they are not mixed into one."
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
            // The ISO 639-2 code every QuickTime and MPEG-4 track carries (`und` when unset, as ffmpeg
            // writes it); the extended tag only when there is no code, so two tracks are compared alike.
            let code = (try? await track.load(.languageCode)) ?? nil
            let extended = code == nil ? ((try? await track.load(.extendedLanguageTag)) ?? nil) : nil
            facts.append(.init(channels: channels, alternateGroup: group, language: code ?? extended))
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
    /// Mixes every channel of every audio track of `input` into a 16 kHz mono 16-bit WAV at `output`: each
    /// track's channels combined by `RecordingMixPlan.channelWeight`, the tracks summed through
    /// `FloatTrackMixer.limitedSample`. Throws for alternate tracks, an unreadable file, or a decode that
    /// stops more than half a second short of where the audio tracks end; `output` is then removed.
    static func mixEveryChannel(of input: URL, to output: URL) async throws -> Result {
        let (asset, tracks, facts, end) = try await open(input)
        let weights = facts.map { RecordingMixPlan.channelWeight(channels: $0.channels) }
        do {
            let handle = try writer(at: output, expectedSeconds: end)
            defer { try? handle.close() }
            let frames = try readInStep(asset: asset, tracks: tracks, channels: facts.map(\.channels)) { _, count, lanes in
                var block = Data(count: count * 2)
                block.withUnsafeMutableBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for frame in 0..<count {
                        var sum = 0.0
                        for (track, channels) in lanes.enumerated() {
                            var total = 0.0
                            for channel in channels { total += Double(channel[frame]) }
                            sum += weights[track] * total
                        }
                        samples[frame] = FloatTrackMixer.limitedSample(sum: Float(sum)).littleEndian
                    }
                }
                try handle.write(contentsOf: block)
            }
            try finishWAV(handle, frames: frames, expectedSeconds: end)
            let duration = Double(frames) / Double(sampleRate)
            if end - duration > 0.5 { throw Failure.shortDecode(expected: end, decoded: duration) }
            return Result(tracks: tracks.count, channels: facts.reduce(0) { $0 + $1.channels }, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Measures `copy`, a mono recording made from `original`, against every channel of `original`'s
    /// tracks read the way the mixer reads them, window by window (`RecordingMixPlan.Audit`), for Shrink
    /// to judge before it deletes anything (review of F942, R2). One pass, in step with the copy, which is
    /// read with AVAudioFile at 16 kHz — what Shrink writes. Frames past the copy's end are not measured:
    /// the length check judges the end.
    static func audit(of original: URL, against copy: URL) async throws -> RecordingMixPlan.Audit {
        let (asset, tracks, facts, _) = try await open(original)
        let copyFile: AVAudioFile
        do { copyFile = try AVAudioFile(forReading: copy) } catch { throw Failure.unreadable(error.localizedDescription) }
        guard copyFile.processingFormat.sampleRate == Double(sampleRate), copyFile.processingFormat.channelCount == 1 else {
            throw Failure.unreadable("the copy is not 16 kHz mono")
        }
        let copyReader = MonoReader(file: copyFile)
        let channels = facts.map(\.channels)
        let channelCount = channels.reduce(0, +)
        // More channels than the check fits one by one are not measured at all: the plan refuses them.
        guard channelCount <= RecordingMixPlan.mostCheckedChannels else {
            return RecordingMixPlan.Audit(trackChannels: channels, sampleRate: Double(sampleRate), windows: [])
        }
        let perWindow = Int(MeetingStoragePlan.levelWindowSeconds * Double(sampleRate))
        var windows: [RecordingMixPlan.Audit.Window] = []
        var gram = [Double](repeating: 0, count: channelCount * channelCount)
        var projection = [Double](repeating: 0, count: channelCount)
        var copySquares = 0.0, frames = 0.0, current = 0
        func close() {
            // Only the upper triangle was summed; the matrix is symmetric.
            for i in 0..<channelCount { for j in 0..<i { gram[i * channelCount + j] = gram[j * channelCount + i] } }
            while windows.count < current {
                windows.append(.init(frames: 0, gram: [Double](repeating: 0, count: channelCount * channelCount),
                                     projection: [Double](repeating: 0, count: channelCount), copySquares: 0))
            }
            windows.append(.init(frames: frames, gram: gram, projection: projection, copySquares: copySquares))
            for k in gram.indices { gram[k] = 0 }
            for k in projection.indices { projection[k] = 0 }
            copySquares = 0
            frames = 0
        }
        var sample = [Double](repeating: 0, count: channelCount)
        _ = try readInStep(asset: asset, tracks: tracks, channels: channels) { start, count, lanes in
            let (copied, valid) = try copyReader.read(count)
            for frame in 0..<valid {
                let index = (start + frame) / perWindow
                if index != current {
                    if frames > 0 { close() }
                    current = index
                }
                var channel = 0
                for samples in lanes {
                    for values in samples { sample[channel] = Double(values[frame]); channel += 1 }
                }
                let c = Double(copied[frame])
                frames += 1
                copySquares += c * c
                for i in 0..<channelCount {
                    let x = sample[i]
                    projection[i] += x * c
                    let row = i * channelCount
                    for j in i..<channelCount { gram[row + j] += x * sample[j] }
                }
            }
        }
        if frames > 0 { close() }
        return RecordingMixPlan.Audit(trackChannels: channels, sampleRate: Double(sampleRate), windows: windows)
    }

    // MARK: - Reading

    /// The asset, its audio tracks, what they hold, and where its audio ends; refuses what cannot be mixed.
    private static func open(_ input: URL) async throws -> (AVAsset, [AVAssetTrack], [RecordingMixPlan.Track], TimeInterval) {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        let end: TimeInterval
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            end = try await audioEnd(of: tracks)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let facts = await Self.facts(of: tracks, in: asset)
        if case let .unsupported(refusal) = RecordingMixPlan.decision(for: facts) { throw Failure.notMixable(refusal) }
        guard !tracks.isEmpty else { throw Failure.unreadable("no audio tracks") }
        return (asset, tracks, facts, end)
    }

    /// One track being read: its output, its channel count, and its channels' samples read but not yet
    /// handed on, which start at frame `start` of the timeline.
    private struct Lane {
        let output: AVAssetReaderTrackOutput
        let channels: Int
        var pending: [[Float]]
        var start = 0
        var finished = false
        var count: Int { pending.first?.count ?? 0 }
        var end: Int { start + count }
    }

    /// Reads every audio track at 16 kHz, each channel apart, in step, and hands `body` each stretch of the
    /// timeline in order: its first frame, its length, and for each track its channels' samples over it
    /// (silence where the track has none). Returns the frames handed on.
    static func readInStep(asset: AVAsset, tracks: [AVAssetTrack], channels: [Int],
                           body: (_ start: Int, _ count: Int, _ lanes: [[[Float]]]) throws -> Void) throws -> Int {
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
            lanes.append(Lane(output: trackOutput, channels: count, pending: [[Float]](repeating: [], count: count)))
        }
        guard reader.startReading() else {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "the reader did not start")
        }
        defer { reader.cancelReading() }
        var handed = 0

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
            // Its place on the timeline. A gap before it is silence; frames at or before what is already
            // placed — an overlap, which a well-formed track does not have, or a stretch already handed on
            // — are dropped, so what was placed first stands.
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            let first = time.isNumeric ? Int(saturating: (time.seconds * Double(sampleRate)).rounded()) : lanes[index].end
            if lanes[index].count == 0, lanes[index].end < handed { lanes[index].start = handed }
            let end = lanes[index].end
            let skip = Swift.max(0, end - first)
            guard skip < frames else { return }
            let gap = Swift.max(0, first - end)
            for channel in 0..<count {
                if gap > 0 { lanes[index].pending[channel].append(contentsOf: repeatElement(0, count: gap)) }
                for frame in skip..<frames { lanes[index].pending[channel].append(interleaved[frame * count + channel]) }
            }
        }

        while true {
            for index in lanes.indices where !lanes[index].finished && lanes[index].end <= handed {
                try pull(index)
            }
            let live = lanes.filter { !$0.finished }
            let target = live.isEmpty ? (lanes.map(\.end).max() ?? handed) : (live.map(\.end).min() ?? handed)
            if target > handed {
                let count = target - handed
                let stretch: [[[Float]]] = lanes.map { lane in
                    lane.pending.map { samples in
                        var out = [Float](repeating: 0, count: count)
                        let from = Swift.max(handed, lane.start), to = Swift.min(target, lane.end)
                        if to > from { for frame in from..<to { out[frame - handed] = samples[frame - lane.start] } }
                        return out
                    }
                }
                try body(handed, count, stretch)
                handed = target
                for index in lanes.indices where lanes[index].start < handed {
                    let drop = Swift.min(lanes[index].count, handed - lanes[index].start)
                    for channel in lanes[index].pending.indices { lanes[index].pending[channel].removeFirst(drop) }
                    lanes[index].start += drop
                }
            }
            if live.isEmpty { break }
        }
        return handed
    }

    /// A mono AVAudioFile read in order, `count` frames at a time; silence past its end.
    private final class MonoReader {
        let file: AVAudioFile
        private var buffered: [Float] = []

        init(file: AVAudioFile) { self.file = file }

        /// The next `count` frames, and how many of them the file held (the rest are silence past its end).
        func read(_ count: Int) throws -> (samples: [Float], valid: Int) {
            while buffered.count < count, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { break }
                try file.read(into: buffer)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let data = buffer.floatChannelData?[0] else { break }
                buffered.append(contentsOf: UnsafeBufferPointer(start: data, count: frames))
            }
            var out = Array(buffered.prefix(count))
            buffered.removeFirst(out.count)
            let valid = out.count
            if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
            return (out, valid)
        }
    }

    // MARK: - Writing

    /// A WAV at `output` whose header room is reserved: the classic 44 bytes every reader takes, unless the
    /// audio's length (with a tenth to spare) could need RF64, past about 37 hours at 16 kHz (F302's rule,
    /// as the recovery rebuild applies it).
    private static func writer(at output: URL, expectedSeconds: TimeInterval) throws -> FileHandle {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: output) } catch { throw Failure.unreadable(error.localizedDescription) }
        try handle.write(contentsOf: Data(count: reservedHeader(expectedSeconds: expectedSeconds)))
        return handle
    }

    private static func reservedHeader(expectedSeconds: TimeInterval) -> Int {
        let seconds = expectedSeconds.isFinite ? Swift.max(0, expectedSeconds) : 0
        let estimate = UInt64(clamping: Int64(saturating: seconds * 1.1 * Double(sampleRate) * 2))
        return WAVWriter.headerLength(dataByteCount: estimate)
    }

    private static func finishWAV(_ handle: FileHandle, frames: Int, expectedSeconds: TimeInterval) throws {
        let rf64 = reservedHeader(expectedSeconds: expectedSeconds) == 80
        let bytes = UInt64(frames) * 2
        guard rf64 || bytes <= WAVWriter.classicDataLimit else {
            throw Failure.unreadable("the mix ran far past the recording's declared length")
        }
        let header = WAVWriter.header(sampleRate: UInt32(sampleRate), dataByteCount64: bytes, forceRF64: rf64)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
    }
}
