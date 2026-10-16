import Accelerate
import AVFoundation
import Foundation
import os
import WhisperCore

/// Mixes every channel of every audio track of a recording into one 16 kHz mono 16-bit WAV (F942), for
/// the engines and speaker analysis — and for Shrink, held back behind `MeetingStoragePlan.shrinkMixesRecordings`
/// — and measures a mono copy against the tracks it was made from (`audit`), so that Shrink deletes nothing a
/// mix or an encode lost (F980). `RecordingMixPlan` decides
/// when, combines a track's channels (`channelWeight`) and judges the measurement; this reads and writes.
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
    /// The most frames `readInStep` hands on at once: four seconds.
    static let longestStretch = 4 * sampleRate

    struct Result: Equatable, Sendable {
        /// How many tracks, and how many channels in all, were summed.
        var tracks: Int
        var channels: Int
        /// The mix's length, from the frames written.
        var duration: TimeInterval
        /// Samples that were NaN or infinite, mixed as silence (second review of F942, D2).
        var silencedSamples = 0
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispermeet.app",
                                       category: "RecordingMixer")

    enum Failure: LocalizedError, Equatable {
        case notMixable(RecordingMixPlan.Refusal)
        case unreadable(String)
        case shortDecode(expected: TimeInterval, decoded: TimeInterval)
        /// A track's audio is timed past the end of the recording's audio: a corrupt timestamp.
        case implausibleTiming
        /// The tracks are timed to run far longer than the audio they hold (`RecordingMixPlan.longestMix`):
        /// an edit list that places a track far in, say. `claimed` is where they end, `held` their audio.
        case implausibleLength(claimed: TimeInterval, held: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notMixable(.alternateTracks):
                return "This recording's audio tracks are in different languages, alternatives to each other, so they are not mixed into one."
            case .notMixable(.unreadableTrack), .unreadable:
                return "This recording's audio tracks could not be read to mix them into one."
            case let .shortDecode(expected, decoded):
                return "Mixing this recording's audio tracks stopped at \(TranscriptFormatter.clock(decoded)) of \(TranscriptFormatter.clock(expected))."
            case .implausibleTiming:
                return "This recording's audio tracks could not be mixed into one: one of them is timed past the end of the recording's audio."
            case let .implausibleLength(claimed, held):
                return "This recording's audio tracks could not be mixed into one: they are timed to run \(TranscriptFormatter.clock(claimed)) but hold only \(TranscriptFormatter.clock(held)) of audio, so their timing looks damaged."
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

    /// `audioEnd`, once shown to be no further than the audio the tracks hold allows
    /// (`RecordingMixPlan.longestMix`); throws `Failure.implausibleLength` past it, before anything is read
    /// (second review of F942, N16). What a track holds is the media its edit list maps — each non-empty
    /// segment's source duration — and for a track that lists no segments, its time range. An edit list's
    /// empty edit maps no media: AVAssetReader hands it back as silence of its own, so without this bound
    /// an edit list placing a track an hour in became an hour of mix.
    static func boundedAudioEnd(of tracks: [AVAssetTrack]) async throws -> TimeInterval {
        let end: TimeInterval
        var held = 0.0
        do {
            end = try await audioEnd(of: tracks)
            for track in tracks {
                let segments = try await track.load(.segments)
                let seconds = segments.isEmpty
                    ? [try await track.load(.timeRange).duration.seconds]
                    : segments.filter { !$0.isEmpty }.map(\.timeMapping.source.duration.seconds)
                held += seconds.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
            }
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard end <= RecordingMixPlan.longestMix(heldSeconds: held) else {
            throw Failure.implausibleLength(claimed: end, held: held)
        }
        return end
    }
    /// Mixes every channel of every audio track of `input` into a 16 kHz mono 16-bit WAV at `output`: each
    /// track's channels combined by `RecordingMixPlan.channelWeight`, the tracks summed through
    /// `FloatTrackMixer.limitedSample`. Throws for alternate tracks, an unreadable file, or a decode that
    /// stops more than half a second short of where the audio tracks end; `output` is then removed.
    ///
    /// A sample that is NaN or infinite — a float recording can carry either — is mixed as silence, that
    /// sample alone, and the count is logged and returned (second review of F942, D2). Summed as it was, one
    /// such sample made its whole frame NaN or infinite, which the limiter turns into silence or the rail, so
    /// one bad channel silenced every other channel the engines should hear. Silencing it rather than
    /// failing the mix: transcription deletes nothing, the bad samples hold no sound to keep, and a failed mix
    /// would fail the same way on every retry, since the file does not change.
    static func mixEveryChannel(of input: URL, to output: URL) async throws -> Result {
        let (asset, tracks, facts, end) = try await open(input)
        let weights = facts.map { RecordingMixPlan.channelWeight(channels: $0.channels) }
        do {
            let handle = try writer(at: output, expectedSeconds: end)
            defer { try? handle.close() }
            var silenced = 0
            var silencedChannels = Set<Int>()
            let frames = try readInStep(asset: asset, tracks: tracks, channels: facts.map(\.channels), audioEnd: end) { _, count, lanes in
                var block = Data(count: count * 2)
                block.withUnsafeMutableBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for frame in 0..<count {
                        var sum = 0.0
                        var first = 0
                        for (track, channels) in lanes.enumerated() {
                            var total = 0.0
                            for (index, channel) in channels.enumerated() {
                                let value = channel[frame]
                                if value.isFinite {
                                    total += Double(value)
                                } else {
                                    silenced += 1
                                    silencedChannels.insert(first + index)
                                }
                            }
                            sum += weights[track] * total
                            first += channels.count
                        }
                        samples[frame] = FloatTrackMixer.limitedSample(sum: Float(sum)).littleEndian
                    }
                }
                try handle.write(contentsOf: block)
            }
            try finishWAV(handle, frames: frames, expectedSeconds: end)
            let duration = Double(frames) / Double(sampleRate)
            if end - duration > 0.5 { throw Failure.shortDecode(expected: end, decoded: duration) }
            if silenced > 0 {
                let list = silencedChannels.sorted().map { String($0 + 1) }.joined(separator: ", ")
                logger.warning("Mixed \(input.lastPathComponent, privacy: .private) with \(silenced) NaN or infinite samples silenced, in channel(s) \(list, privacy: .public) counted over every track; every other sample was mixed as it is.")
            }
            return Result(tracks: tracks.count, channels: facts.reduce(0) { $0 + $1.channels }, duration: duration,
                          silencedSamples: silenced)
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
    ///
    /// AVAssetReader does not read an ffmpeg-made file the same way twice, and its reads drift, each track
    /// on its own and without bound along a file (second review of F942, C3; measured for F980). So the
    /// audit follows each track: in each `auditWindowSeconds` window its channels' projections onto the
    /// copy are taken at every lag within `RecordingMixPlan.alignmentFrames` of where the track stood in
    /// the window before (wider, up to `widestAlignment`, after windows in which it was not found),
    /// `RecordingMixPlan.alignment` picks its step, and the window's Gram matrix and projections are summed
    /// from the channels shifted by their track's place. A track that drifts past `alignmentReach` is
    /// marked in `Audit.outOfStep` and no longer followed. The copy is never shifted, so a channel the copy
    /// lacks cannot pick itself a lag.
    static func audit(of original: URL, against copy: URL) async throws -> RecordingMixPlan.Audit {
        let (asset, tracks, facts, end) = try await open(original)
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
        let step = RecordingMixPlan.alignmentFrames, widest = RecordingMixPlan.widestAlignment, reach = RecordingMixPlan.alignmentReach
        let perWindow = Swift.max(1, Int(saturating: RecordingMixPlan.auditWindowSeconds * Double(sampleRate)))
        // How far a window's alignment can look either side of the window: a track's place and its search.
        let lookaround = reach + widest
        var windows: [RecordingMixPlan.Audit.Window] = []
        var outOfStep: (window: Int, track: Int)?
        // Where each track stands against the copy, and how many windows since it was last found there.
        var place = [Int](repeating: 0, count: channels.count)
        var unfound = [Int](repeating: 0, count: channels.count)
        var trackOf: [Int] = []
        for (track, count) in channels.enumerated() { trackOf += repeatElement(track, count: count) }
        // Each channel's samples from timeline frame `laneStart` on, kept `lookaround` frames behind the
        // next window; the copy's from `copyStart` on, up to where it ended.
        var lanes = [[Float]](repeating: [], count: channelCount)
        var laneStart = 0
        var copyBuffer: [Float] = []
        var copyStart = 0
        var copyEnd: Int?
        var nextWindow = 0
        var handed = 0

        /// Closes the window `[nextWindow, upTo)`: aligns each track, sums the window into the audit.
        func closeWindow(upTo windowEnd: Int) {
            let measuredEnd = Swift.min(windowEnd, copyEnd ?? windowEnd)
            let n = measuredEnd - nextWindow
            defer {
                let keepFrom = windowEnd - lookaround
                if keepFrom > laneStart {
                    for channel in lanes.indices { lanes[channel].removeFirst(Swift.min(lanes[channel].count, keepFrom - laneStart)) }
                    laneStart = keepFrom
                }
                if windowEnd > copyStart {
                    copyBuffer.removeFirst(Swift.min(copyBuffer.count, windowEnd - copyStart))
                    copyStart = windowEnd
                }
                nextWindow = windowEnd
            }
            guard n > 0 else { return }
            let index = windows.count
            var c = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let at = nextWindow + k - copyStart
                if at >= 0 && at < copyBuffer.count { c[k] = copyBuffer[at] }
            }
            // Each track's search this window: `step` either side of its place, wider the longer it has
            // not been found. Each of its channels over the window and that far either side of its place:
            // silence before the recording's start, and the lane's own silence past its end.
            let span = channels.indices.map { Swift.min(widest, step * (1 + unfound[$0])) }
            let padded: [[Float]] = (0..<channelCount).map { channel in
                let track = trackOf[channel], s = span[track]
                var out = [Float](repeating: 0, count: n + 2 * s)
                for k in out.indices {
                    let at = nextWindow + place[track] - s + k - laneStart
                    if at >= 0 && at < lanes[channel].count { out[k] = lanes[channel][at] }
                }
                return out
            }
            // Σ xᵢ[t + place + lag] · c[t] for every lag in −s…s: a correlation, F forward. And each
            // channel's energy over the window shifted by each lag, from a running sum of its squares,
            // which "found" is measured against.
            var projectionsByLag: [[Double]] = []
            var energiesByLag: [[Double]] = []
            for channel in 0..<channelCount {
                let s = span[trackOf[channel]], count = 2 * s + 1
                var out = [Float](repeating: 0, count: count)
                vDSP_conv(padded[channel], 1, c, 1, &out, 1, vDSP_Length(count), vDSP_Length(n))
                projectionsByLag.append(out.map(Double.init))
                var running = 0.0
                var prefix = [Double](repeating: 0, count: padded[channel].count + 1)
                for (k, value) in padded[channel].enumerated() { running += Double(value) * Double(value); prefix[k + 1] = running }
                energiesByLag.append((0..<count).map { prefix[$0 + n] - prefix[$0] })
            }
            var copySquares: Float = 0
            vDSP_dotpr(c, 1, c, 1, &copySquares, vDSP_Length(n))
            func align(_ projections: [[Double]], _ energies: [[Double]], _ tracks: [Int]) -> [Int?] {
                RecordingMixPlan.alignment(projectionsByLag: projections, energiesByLag: energies, copySquares: Double(copySquares),
                                           trackChannels: tracks)
            }
            var steps = align(projectionsByLag, energiesByLag, channels)
            /// The window's sums with each channel shifted by its track's step: `padded[i]` from `span + step`.
            func sums(_ steps: [Int?]) -> (gram: [Double], projection: [Double], offset: [Int]) {
                let offset = (0..<channelCount).map { span[trackOf[$0]] + (steps[trackOf[$0]] ?? 0) }
                var gram = [Double](repeating: 0, count: channelCount * channelCount)
                var projection = [Double](repeating: 0, count: channelCount)
                for i in 0..<channelCount {
                    projection[i] = projectionsByLag[i][offset[i]]
                    for j in i..<channelCount {
                        var dot: Float = 0
                        padded[i].withUnsafeBufferPointer { pi in
                            padded[j].withUnsafeBufferPointer { pj in
                                vDSP_dotpr(pi.baseAddress! + offset[i], 1, pj.baseAddress! + offset[j], 1, &dot, vDSP_Length(n))
                            }
                        }
                        gram[i * channelCount + j] = Double(dot)
                        gram[j * channelCount + i] = Double(dot)
                    }
                }
                return (gram, projection, offset)
            }
            // A track whose sound the copy also holds inside another track (OBS's microphone, inside its
            // master) has two images in the copy, a few frames apart from the mixer's own read, and the raw
            // projection can lock onto the other track's image of it: the joint fit then sees it at half.
            // So each track is aligned again against the copy less the other tracks' fitted contributions,
            // where only its own image remains (F978's residual test), and the new alignment is kept only
            // where the track the copy follows least then follows it better, and nothing is explained worse
            // — a pure tone's image half a period on would otherwise pass for it. A track the copy lost finds
            // nothing there, keeps its place, and fails its fit, which is right.
            // Twice: the second pass takes the others out at their improved places.
            for _ in 0..<2 where channels.count > 1 {
                let first = sums(steps)
                let fit = RecordingMixPlan.trackFit(gram: first.gram, projection: first.projection, trackChannels: channels)
                var again = steps
                for track in channels.indices {
                    var residual = c
                    for other in channels.indices where other != track && fit.coefficients[other].isFinite {
                        var scale = -Float(fit.coefficients[other] * RecordingMixPlan.channelWeight(channels: channels[other]))
                        for channel in 0..<channelCount where trackOf[channel] == other {
                            var less = [Float](repeating: 0, count: n)
                            padded[channel].withUnsafeBufferPointer { p in
                                vDSP_vsma(p.baseAddress! + first.offset[channel], 1, &scale, residual, 1, &less, 1, vDSP_Length(n))
                            }
                            residual = less
                        }
                    }
                    let count = 2 * span[track] + 1
                    var own: [[Double]] = [], ownEnergies: [[Double]] = []
                    for channel in 0..<channelCount where trackOf[channel] == track {
                        var out = [Float](repeating: 0, count: count)
                        vDSP_conv(padded[channel], 1, residual, 1, &out, 1, vDSP_Length(count), vDSP_Length(n))
                        own.append(out.map(Double.init))
                        ownEnergies.append(energiesByLag[channel])
                    }
                    if let moved = align(own, ownEnergies, [channels[track]])[0] { again[track] = moved }
                }
                guard again != steps else { break }
                let second = sums(again)
                let after = RecordingMixPlan.trackFit(gram: second.gram, projection: second.projection, trackChannels: channels)
                // Kept only if the track the copy follows least now follows it better: the explained energy
                // alone cannot tell a right move from a wrong one between near-collinear tracks, since any
                // mix of them explains the copy, and a stem once moved to a wrong lag on that criterion while
                // another's fit collapsed (gates/22-final-targeted.log).
                func least(_ coefficients: [Double]) -> Double { coefficients.filter(\.isFinite).min() ?? -.infinity }
                guard least(after.coefficients) > least(fit.coefficients), after.explained >= fit.explained else { break }
                steps = again
            }
            var lags: [Int] = []
            for track in channels.indices {
                if let found = steps[track] {
                    place[track] += found
                    unfound[track] = 0
                    if abs(place[track]) > reach, outOfStep == nil { outOfStep = (index, track) }
                } else {
                    unfound[track] += 1
                }
                lags.append(place[track])
            }
            let final = sums(steps)
            windows.append(.init(frames: Double(n), gram: final.gram, projection: final.projection, copySquares: Double(copySquares), lags: lags))
        }

        _ = try readInStep(asset: asset, tracks: tracks, channels: channels, audioEnd: end) { start, count, stretch in
            var channel = 0
            for samples in stretch {
                for values in samples { lanes[channel].append(contentsOf: values); channel += 1 }
            }
            if copyEnd == nil {
                let (copied, valid) = try copyReader.read(count)
                copyBuffer.append(contentsOf: copied.prefix(valid))
                if valid < count { copyEnd = start + valid }
            }
            handed = start + count
            // A window is closed once its alignment can look as far past its end as it may need to.
            while nextWindow + perWindow + lookaround <= handed { closeWindow(upTo: nextWindow + perWindow) }
        }
        // What is left, the recording's last partial window included: past its end the lanes hold silence.
        while nextWindow < handed { closeWindow(upTo: Swift.min(nextWindow + perWindow, handed)) }
        return RecordingMixPlan.Audit(trackChannels: channels, sampleRate: Double(sampleRate), windows: windows, outOfStep: outOfStep)
    }

    /// Measures a two-channel, one-track recording against its mono copy for `RecordingMixPlan.firstChannelNotInCopy`
    /// to judge before Shrink deletes it (F1001). The recording is read as `audit` reads it — 16 kHz, each
    /// channel apart — and the copy with AVAudioFile at 16 kHz, in step, and two links are measured from the
    /// one read:
    ///
    /// - **Whether the channels cancel in the mix** (`CancellationLink`): every
    ///   `RecordingMixPlan.cancellationFrameSeconds` frame of each channel (Hann, half-overlapping) is
    ///   transformed; per bin, over each stretch of `cancellationGroupFrames` frames, the channels'
    ///   cross-spectrum, their energies and how the energy is spread over the frames are summed; the stretch's
    ///   delays are found from its cross-correlation (`alignmentFrames16k`), and each bin's cancellation read at
    ///   its best alignment (`RecordingMixPlan.cancels`), per band of `cancellationBands`. Every frame of the
    ///   recording is measured, the last padded with silence. The copy plays no part.
    /// - **Whether the copy holds the mix** (`CopyLink`): `presenceFrameSeconds` frames of the mix, formed as
    ///   the encode mixes (`channelWeight`), and of the copy; per bin in `presenceBand`, over
    ///   `presenceGroupFrames` frames, never across a window's edge, the copy's projection onto the mix and the
    ///   mix's energy, judged by `soundFound`. A frame reaching past the copy's end is not measured: the length
    ///   check judges the end.
    static func channelPresence(of original: URL, against copy: URL) async throws -> RecordingMixPlan.ChannelPresence {
        let (asset, tracks, facts, end) = try await open(original)
        guard facts.count == 1, facts.first?.channels == 2 else {
            throw Failure.unreadable("not one track of two channels")
        }
        let copyFile: AVAudioFile
        do { copyFile = try AVAudioFile(forReading: copy) } catch { throw Failure.unreadable(error.localizedDescription) }
        guard copyFile.processingFormat.sampleRate == Double(sampleRate), copyFile.processingFormat.channelCount == 1 else {
            throw Failure.unreadable("the copy is not 16 kHz mono")
        }
        let copyReader = MonoReader(file: copyFile)
        let cancellation = try CancellationLink()
        let copyLink = try CopyLink()
        var copyEnd: Int?
        _ = try readInStep(asset: asset, tracks: tracks, channels: [2], audioEnd: end) { start, count, stretch in
            guard let lanes = stretch.first, lanes.count == 2 else { throw Failure.unreadable("a channel was not read") }
            let (copied, valid) = try copyReader.read(count)
            if copyEnd == nil, valid < count { copyEnd = start + valid }
            cancellation.append(left: lanes[0], right: lanes[1])
            copyLink.append(left: lanes[0], right: lanes[1], copy: copied, copyEnd: copyEnd)
        }
        cancellation.finish()
        copyLink.finish(copyEnd: copyEnd)
        return RecordingMixPlan.ChannelPresence(channels: 2, stretches: cancellation.stretches, mix: copyLink.windows)
    }

    /// A real-to-complex transform of `size` samples through a Hann window, for the presence links.
    private final class Spectrum {
        let size: Int
        private let setup: vDSP_DFT_Setup
        private var taper: [Float]
        private var inReal: [Float], inImaginary: [Float]
        var real: [Float], imaginary: [Float]

        init(size: Int) throws {
            guard size >= 16, size & (size - 1) == 0,
                  let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
                throw Failure.unreadable("the frame length cannot be transformed")
            }
            self.size = size
            self.setup = setup
            taper = [Float](repeating: 0, count: size)
            vDSP_hann_window(&taper, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            inReal = [Float](repeating: 0, count: size / 2)
            inImaginary = inReal; real = inReal; imaginary = inReal
        }

        deinit { vDSP_DFT_DestroySetup(setup) }

        /// Transforms `samples[offset ..< offset + size]` (silence past the end) into `real`/`imaginary`.
        func transform(_ samples: [Float], from offset: Int) {
            for k in 0..<(size / 2) {
                let even = offset + 2 * k, odd = even + 1
                inReal[k] = (even < samples.count ? samples[even] : 0) * taper[2 * k]
                inImaginary[k] = (odd < samples.count ? samples[odd] : 0) * taper[2 * k + 1]
            }
            vDSP_DFT_Execute(setup, inReal, inImaginary, &real, &imaginary)
        }
    }

    /// Link 1 of `channelPresence`: whether the two channels cancel when they are mixed into one, per stretch
    /// and band (F1001, round 2).
    private final class CancellationLink {
        private let left: Spectrum, right: Spectrum
        private let size: Int, hop: Int
        private let lowBin: Int, bins: Int
        private let bandOf: [Int]
        private let bandCount: Int
        private let lags: [Int]
        /// cos and sin of each bin's phase at each lag, lag-major.
        private let cosines: [Double], sines: [Double]
        // Per bin over the stretch: Σ L·conj(R), Σ|L|², Σ|R|², Σ|L||R| and Σ|L|²|R|².
        private var crossReal: [Double], crossImaginary: [Double], leftEnergy: [Double], rightEnergy: [Double]
        private var products: [Double], productSquares: [Double]
        private var squares = 0.0, samples = 0.0, frames = 0
        // Each channel's samples from frame `bufferStart` of the recording on; the next frame starts at `next`.
        private var leftLane: [Float] = [], rightLane: [Float] = []
        private var bufferStart = 0, next = 0, received = 0
        private(set) var stretches: [RecordingMixPlan.ChannelPresence.Stretch] = []

        init() throws {
            let size = Int(saturating: (RecordingMixPlan.cancellationFrameSeconds * Double(RecordingMixer.sampleRate)).rounded())
            self.size = size
            hop = size / 2
            left = try Spectrum(size: size)
            right = try Spectrum(size: size)
            let edges = RecordingMixPlan.cancellationBands
            let binWidth = Double(RecordingMixer.sampleRate) / Double(size)
            let low = Swift.max(1, Int(saturating: ((edges.first ?? 0) / binWidth).rounded(.up)))
            let highBin = Swift.min(size / 2 - 1, Int(saturating: ((edges.last ?? 0) / binWidth).rounded(.down)))
            let count = Swift.max(0, highBin - low + 1), bandsCount = Swift.max(0, edges.count - 1)
            lowBin = low; bins = count; bandCount = bandsCount
            bandOf = (0..<count).map { bin in
                let frequency = Double(low + bin) * binWidth
                return Swift.min(Swift.max(0, bandsCount - 1), Swift.max(0, (edges.lastIndex { $0 <= frequency } ?? 0)))
            }
            let reach = RecordingMixPlan.alignmentFrames16k
            let allLags = Array(-reach...reach)
            lags = allLags
            var cosineTable: [Double] = [], sineTable: [Double] = []
            for lag in allLags {
                for bin in 0..<count {
                    let phase = 2 * Double.pi * Double(low + bin) / Double(size) * Double(lag)
                    cosineTable.append(cos(phase)); sineTable.append(sin(phase))
                }
            }
            cosines = cosineTable; sines = sineTable
            let zeros = [Double](repeating: 0, count: count)
            crossReal = zeros; crossImaginary = zeros; leftEnergy = zeros; rightEnergy = zeros
            products = zeros; productSquares = zeros
        }

        func append(left newLeft: [Float], right newRight: [Float]) {
            leftLane.append(contentsOf: newLeft)
            rightLane.append(contentsOf: newRight)
            received += Swift.min(newLeft.count, newRight.count)
            measureReady(upTo: received)
        }

        /// The last frames, past the recording's end silence, so every one of its samples is measured.
        func finish() {
            leftLane.append(contentsOf: repeatElement(0, count: size))
            rightLane.append(contentsOf: repeatElement(0, count: size))
            measureReady(upTo: bufferStart + leftLane.count)
            closeStretch()
        }

        private func measureReady(upTo available: Int) {
            while next + size <= available, next < received {
                measureFrame()
                next += hop
            }
            let drop = Swift.min(next - bufferStart, leftLane.count, rightLane.count)
            if drop > 0 {
                leftLane.removeFirst(drop); rightLane.removeFirst(drop)
                bufferStart += drop
            }
        }

        private func measureFrame() {
            let offset = next - bufferStart
            left.transform(leftLane, from: offset)
            right.transform(rightLane, from: offset)
            for bin in 0..<bins {
                let k = lowBin + bin
                let a = Double(left.real[k]), b = Double(left.imaginary[k])
                let c = Double(right.real[k]), d = Double(right.imaginary[k])
                crossReal[bin] += a * c + b * d
                crossImaginary[bin] += b * c - a * d
                let pl = a * a + b * b, pr = c * c + d * d
                leftEnergy[bin] += pl; rightEnergy[bin] += pr
                products[bin] += (pl * pr).squareRoot(); productSquares[bin] += pl * pr
            }
            // The level: each frame owns the hop it starts, inside the recording.
            for index in offset..<Swift.min(offset + hop, received - bufferStart) {
                let l = Double(leftLane[index]), r = Double(rightLane[index])
                squares += l * l + r * r
                samples += 2
            }
            frames += 1
            if frames == RecordingMixPlan.cancellationGroupFrames { closeStretch() }
        }

        private func closeStretch() {
            defer {
                frames = 0; squares = 0; samples = 0
                for bin in 0..<bins {
                    crossReal[bin] = 0; crossImaginary[bin] = 0; leftEnergy[bin] = 0; rightEnergy[bin] = 0
                    products[bin] = 0; productSquares[bin] = 0
                }
            }
            guard frames > 0 else { return }
            // The delays the stretch's sound arrives with: the strongest peaks of its normalized cross-correlation.
            let norm = (leftEnergy.reduce(0, +) * rightEnergy.reduce(0, +)).squareRoot()
            var correlation = [Double](repeating: 0, count: lags.count)
            if norm > 0, norm.isFinite {
                for index in lags.indices {
                    var sum = 0.0
                    let base = index * bins
                    for bin in 0..<bins { sum += crossReal[bin] * cosines[base + bin] + crossImaginary[bin] * sines[base + bin] }
                    correlation[index] = sum / norm
                }
            }
            let zero = lags.firstIndex(of: 0) ?? 0
            var peaks: [(index: Int, value: Double)] = []
            for index in lags.indices where index != zero && correlation[index] >= RecordingMixPlan.alignmentMinimumCorrelation
                && (index == 0 || correlation[index] >= correlation[index - 1])
                && (index == lags.count - 1 || correlation[index] >= correlation[index + 1]) {
                peaks.append((index, correlation[index]))
            }
            let alignments = [zero] + peaks.sorted { $0.value > $1.value }.prefix(RecordingMixPlan.alignmentCandidates).map(\.index)
            var bands = [RecordingMixPlan.ChannelPresence.Measure](repeating: .init(energy: 0, missing: 0), count: bandCount)
            for bin in 0..<bins {
                var best = -Double.infinity
                for index in alignments {
                    best = Swift.max(best, crossReal[bin] * cosines[index * bins + bin] + crossImaginary[bin] * sines[index * bins + bin])
                }
                let energies = leftEnergy[bin] * rightEnergy[bin]
                let coherence = energies > 0 ? (crossReal[bin] * crossReal[bin] + crossImaginary[bin] * crossImaginary[bin]) / energies : 0
                let spread = productSquares[bin] > 0 ? products[bin] * products[bin] / productSquares[bin] : 0
                let band = bandOf[bin]
                bands[band].energy += (leftEnergy[bin] + rightEnergy[bin]) / 2
                bands[band].missing += RecordingMixPlan.cancels(alignedReal: best, coherence: coherence, frames: spread)
            }
            let start = Double(stretches.count * RecordingMixPlan.cancellationGroupFrames * hop) / Double(RecordingMixer.sampleRate)
            stretches.append(.init(start: start, level: samples > 0 ? (squares / samples).squareRoot() : 0, bands: bands))
        }
    }

    /// Link 2 of `channelPresence`: whether the copy holds the channels' mix, per `levelWindowSeconds` window.
    private final class CopyLink {
        private let mixSpectrum: Spectrum, copySpectrum: Spectrum
        private let size: Int, hop: Int, lowBin: Int, bins: Int, perWindow: Int
        private let weight = RecordingMixPlan.channelWeight(channels: 2)
        private var crossReal: [Double], crossImaginary: [Double], energy: [Double]
        private var groupFrames = 0, groupWindow = 0
        private var mixLane: [Float] = [], copyLane: [Float] = []
        private var bufferStart = 0, next = 0, received = 0
        private(set) var windows: [RecordingMixPlan.ChannelPresence.Measure] = []

        init() throws {
            size = Int(saturating: (RecordingMixPlan.presenceFrameSeconds * Double(RecordingMixer.sampleRate)).rounded())
            hop = size / 2
            mixSpectrum = try Spectrum(size: size)
            copySpectrum = try Spectrum(size: size)
            let binWidth = Double(RecordingMixer.sampleRate) / Double(size)
            lowBin = Swift.max(1, Int(saturating: (RecordingMixPlan.presenceBand.lowerBound / binWidth).rounded(.up)))
            let highBin = Swift.min(size / 2 - 1, Int(saturating: (RecordingMixPlan.presenceBand.upperBound / binWidth).rounded(.down)))
            bins = Swift.max(0, highBin - lowBin + 1)
            perWindow = Swift.max(1, Int(saturating: MeetingStoragePlan.levelWindowSeconds * Double(RecordingMixer.sampleRate)))
            crossReal = [Double](repeating: 0, count: bins)
            crossImaginary = crossReal; energy = crossReal
        }

        func append(left: [Float], right: [Float], copy: [Float], copyEnd: Int?) {
            let count = Swift.min(left.count, right.count, copy.count)
            for index in 0..<count { mixLane.append(Float(weight) * (left[index] + right[index])) }
            copyLane.append(contentsOf: copy.prefix(count))
            received += count
            measureReady(upTo: received, copyEnd: copyEnd)
        }

        func finish(copyEnd: Int?) {
            mixLane.append(contentsOf: repeatElement(0, count: size))
            copyLane.append(contentsOf: repeatElement(0, count: size))
            measureReady(upTo: bufferStart + mixLane.count, copyEnd: copyEnd)
            closeGroup()
        }

        private func measureReady(upTo available: Int, copyEnd: Int?) {
            while next + size <= available, next < received {
                if copyEnd.map({ next + size <= $0 }) ?? true { measureFrame() }
                next += hop
            }
            let drop = Swift.min(next - bufferStart, mixLane.count, copyLane.count)
            if drop > 0 {
                mixLane.removeFirst(drop); copyLane.removeFirst(drop)
                bufferStart += drop
            }
        }

        private func measureFrame() {
            let window = (next + hop) / perWindow
            if groupFrames > 0, window != groupWindow || groupFrames >= RecordingMixPlan.presenceGroupFrames { closeGroup() }
            groupWindow = window
            let offset = next - bufferStart
            mixSpectrum.transform(mixLane, from: offset)
            copySpectrum.transform(copyLane, from: offset)
            for bin in 0..<bins {
                let k = lowBin + bin
                let mr = Double(mixSpectrum.real[k]), mi = Double(mixSpectrum.imaginary[k])
                let cr = Double(copySpectrum.real[k]), ci = Double(copySpectrum.imaginary[k])
                // copy × conj(mix)
                crossReal[bin] += cr * mr + ci * mi
                crossImaginary[bin] += ci * mr - cr * mi
                energy[bin] += mr * mr + mi * mi
            }
            groupFrames += 1
        }

        private func closeGroup() {
            defer { groupFrames = 0 }
            guard groupFrames > 0 else { return }
            while windows.count <= groupWindow { windows.append(.init(energy: 0, missing: 0)) }
            var held = 0.0, lost = 0.0
            for bin in 0..<bins {
                let projection = (crossReal[bin] * crossReal[bin] + crossImaginary[bin] * crossImaginary[bin]).squareRoot()
                held += energy[bin]
                if !RecordingMixPlan.soundFound(projection: projection, energy: energy[bin], weight: 1) { lost += energy[bin] }
                crossReal[bin] = 0; crossImaginary[bin] = 0; energy[bin] = 0
            }
            windows[groupWindow].energy += held
            windows[groupWindow].missing += lost
        }
    }

    // MARK: - Reading

    /// The asset, its audio tracks, what they hold, and where its audio ends; refuses what cannot be mixed.
    private static func open(_ input: URL) async throws -> (AVAsset, [AVAssetTrack], [RecordingMixPlan.Track], TimeInterval) {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let facts = await Self.facts(of: tracks, in: asset)
        if case let .unsupported(refusal) = RecordingMixPlan.decision(for: facts) { throw Failure.notMixable(refusal) }
        guard !tracks.isEmpty else { throw Failure.unreadable("no audio tracks") }
        // Before anything is read or written: a mix runs no longer than the audio the tracks hold allows.
        let end = try await boundedAudioEnd(of: tracks)
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
    /// (silence where the track has none), at most `longestStretch` frames at a time. Returns the frames
    /// handed on. Throws `Failure.implausibleTiming` for a buffer timed past `audioEnd` and a second (review of
    /// F942). `audioEnd` itself is bounded by the audio the tracks hold (`boundedAudioEnd`, which `open`
    /// applies): bounding a buffer by the tracks' time range alone did not catch an edit list that sets that
    /// range (second review, N16).
    static func readInStep(asset: AVAsset, tracks: [AVAssetTrack], channels: [Int], audioEnd: TimeInterval,
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
        let limit = RecordingMixPlan.placementLimit(audioEnd: audioEnd, rate: Double(sampleRate))

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
            // Its place on the timeline, within the audio's own length (`RecordingMixPlan.placement`): a
            // late start stores nothing for the silence before it, a gap inside a track is silence, and
            // frames already placed or handed on are dropped, so what was placed first stands.
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            let first = time.isNumeric ? Int(saturating: (time.seconds * Double(sampleRate)).rounded()) : lanes[index].end
            guard let place = RecordingMixPlan.placement(firstFrame: first, frames: frames, laneStart: lanes[index].start,
                                                         laneCount: lanes[index].count, handed: handed, limit: limit) else {
                throw Failure.implausibleTiming
            }
            lanes[index].start = place.laneStart
            guard place.skip < frames else { return }
            for channel in 0..<count {
                if place.gap > 0 { lanes[index].pending[channel].append(contentsOf: repeatElement(0, count: place.gap)) }
                for frame in place.skip..<frames { lanes[index].pending[channel].append(interleaved[frame * count + channel]) }
            }
        }

        while true {
            for index in lanes.indices where !lanes[index].finished && lanes[index].end <= handed {
                try pull(index)
            }
            let live = lanes.filter { !$0.finished }
            let target = live.isEmpty ? (lanes.map(\.end).max() ?? handed) : (live.map(\.end).min() ?? handed)
            // At most `longestStretch` frames at a time, so a gap no track covers is never one allocation
            // the size of the gap (second review of F942).
            while target > handed {
                let count = Swift.min(target - handed, longestStretch), until = handed + count
                let stretch: [[[Float]]] = lanes.map { lane in
                    lane.pending.map { samples in
                        var out = [Float](repeating: 0, count: count)
                        let from = Swift.max(handed, lane.start), to = Swift.min(until, lane.end)
                        if to > from { for frame in from..<to { out[frame - handed] = samples[frame - lane.start] } }
                        return out
                    }
                }
                try body(handed, count, stretch)
                handed = until
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
