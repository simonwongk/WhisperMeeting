import Foundation

/// Whether a recording is mixed into one mono signal before anything listens to it (F942).
///
/// Every decoder the app hands a recording to keeps one track of a container with several: Whisper's
/// ffmpeg decode, the afconvert transcode Qwen, speaker analysis and Shrink run, and `AVAudioFile`
/// (measured on synthetic two-track `.mov`, `.mp4` and `.m4a` files, F801). Inside one track, a WAV
/// with more than two channels and no channel layout is reduced to channel 1 by afconvert's mix, and
/// Whisper's ffmpeg decode guesses a layout from the count and drops the channel it takes for LFE (the
/// 4th of 6 or 8, the 3rd of 3). So a call recorded one side per track, or a "poly" WAV from a field
/// recorder, was transcribed from one track or channel with nothing said. The user's decision
/// (2026-10-12): mix every track into one, for transcription and for Shrink.
///
/// Pure: the app reads each audio track's facts with AVFoundation (`RecordingMixer.tracks(of:)`) and
/// acts on the answer.
public enum RecordingMixPlan {
    /// What one audio track of a recording holds.
    public struct Track: Sendable, Equatable {
        /// How many channels it carries, from its format description.
        public var channels: Int
        /// The alternate group it shares with other audio tracks, or nil. A group alone does not make
        /// tracks alternatives: ffmpeg's MP4 and QuickTime muxer puts every audio track it writes in one
        /// group and enables only the first (review of F942, R3, measured on files from ffmpeg 8.1.2), so
        /// a call saved a side per track by ffmpeg, or by a tool built on it, carries one.
        public var alternateGroup: Int?
        /// Its language tag, or nil when it has none: ffmpeg writes `und`, which counts as none.
        public var language: String?

        public init(channels: Int, alternateGroup: Int? = nil, language: String? = nil) {
            self.channels = channels
            self.alternateGroup = alternateGroup
            let tag = language?.trimmingCharacters(in: .whitespaces).lowercased()
            self.language = tag.flatMap { $0.isEmpty || $0 == "und" ? nil : $0 }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// One track of one or two channels: handed on as it is. The engines' own decodes mix two
        /// channels (ffmpeg's `-ac 1`; afconvert's `--mix`, F796), and Shrink's encode does too.
        case asItIs
        /// Every track is mixed into one mono signal (`channels` of them in all, over the tracks): each
        /// track's channels averaged into its own signal (`channelWeight`), the tracks summed by a capture's
        /// rule, each placed at its own time. That is what the engines, speaker analysis and Shrink get.
        case mixEveryChannel(channels: Int)
        /// Several tracks that should not be summed, or cannot be read: see `Refusal`.
        case unsupported(Refusal)
    }

    public enum Refusal: Sendable, Equatable {
        /// Audio tracks that are alternatives of one another: in one alternate group, and tagged with
        /// different languages. Summing two languages makes neither intelligible, so they are not mixed:
        /// the engines keep decoding the default one, as before, and Shrink refuses rather than delete the
        /// others. The user's decision was to mix every track; another language is not a part of the
        /// recording but another version of it.
        case alternateTracks(count: Int)
        /// A track whose channels could not be read.
        case unreadableTrack
    }

    public static func decision(for tracks: [Track]) -> Decision {
        guard !tracks.isEmpty else { return .asItIs }
        if tracks.contains(where: { $0.channels < 1 }) { return .unsupported(.unreadableTrack) }
        if hasAlternateLanguages(tracks) { return .unsupported(.alternateTracks(count: tracks.count)) }
        if tracks.count == 1, tracks[0].channels <= 2 { return .asItIs }
        return .mixEveryChannel(channels: tracks.reduce(0) { $0 + $1.channels })
    }

    /// Whether two tracks of one alternate group are tagged with two different languages. A group alone
    /// is what ffmpeg writes for every file with several audio tracks (R3).
    static func hasAlternateLanguages(_ tracks: [Track]) -> Bool {
        var languagesByGroup: [Int: Set<String>] = [:]
        for track in tracks {
            guard let group = track.alternateGroup, let language = track.language else { continue }
            languagesByGroup[group, default: []].insert(language)
        }
        return languagesByGroup.values.contains { $0.count > 1 }
    }

    /// What the mix does to the level of the tracks' sum while it fits: the gain `FloatTrackMixer` gives
    /// a capture's two tracks (F345).
    public static var gain: Double { Double(FloatTrackMixer.soloGain) }

    /// The weight each channel of a track of `channels` carries in that track's own signal — the one rule
    /// the mixer combines a track's channels by and the check of a copy expects (`firstFinding`), so the
    /// two cannot drift apart. The average, as a capture combines a microphone's channels
    /// (`MonoDownmixConverter.averagedToMono`, F659): summed instead, a voice on both sides of a stereo
    /// track came out twice as loud beside another track as on every other path, into the limiter's knee
    /// (review of F942). So a track of N channels with one speaking is heard at 1/N of that voice, as a
    /// capture would hear it.
    public static func channelWeight(channels: Int) -> Double { 1 / Double(Swift.max(1, channels)) }

    // MARK: - Placing a track's audio on the timeline (review of F942)

    /// Where a buffer of a track's audio goes, read in step with the others.
    public struct Placement: Sendable, Equatable {
        /// The frame the track's waiting audio starts at, after placing: when nothing was waiting, where
        /// this buffer starts, and never before what was already handed on. So a track that starts late
        /// stores nothing for the silence before it.
        public var laneStart: Int
        /// Frames at the buffer's front dropped: they lie at or before what is already placed or handed on
        /// (an overlap, which a well-formed track does not have), so what was placed first stands.
        public var skip: Int
        /// Silence to place before the buffer's frames: a gap inside the track.
        public var gap: Int

        public init(laneStart: Int, skip: Int, gap: Int) {
            self.laneStart = laneStart
            self.skip = skip
            self.gap = gap
        }
    }

    /// The last frame, at `rate`, a track's audio may be placed up to: the audio's own end — the latest end
    /// of the audio tracks' time ranges — and a second. Saturating, and a second when the end is not a
    /// number.
    public static func placementLimit(audioEnd: TimeInterval, rate: Double) -> Int {
        let seconds = audioEnd.isFinite ? Swift.max(0, audioEnd) : 0
        return Int(saturating: (seconds + 1) * rate)
    }

    /// Where a buffer of `frames` frames presented at `firstFrame` goes in a track's waiting audio, which
    /// holds `laneCount` frames from `laneStart`, with `handed` frames of the timeline already handed on;
    /// or nil when the buffer reaches past `limit` or starts before the timeline (review of F942). The
    /// bound is the file's own audio length, so a corrupt timestamp cannot make a mix allocate, or write,
    /// silence in proportion to it: before this, the mixer padded up to whatever the timestamp said.
    public static func placement(firstFrame: Int, frames: Int, laneStart: Int, laneCount: Int,
                                 handed: Int, limit: Int) -> Placement? {
        guard firstFrame >= 0, frames >= 0, firstFrame <= limit, frames <= limit - firstFrame else { return nil }
        let start = laneCount == 0 ? Swift.max(firstFrame, handed) : laneStart
        let end = start + laneCount
        return Placement(laneStart: start, skip: Swift.min(frames, Swift.max(0, end - firstFrame)),
                         gap: Swift.max(0, firstFrame - end))
    }

    // MARK: - Showing that a copy holds every track (F942, review R2)

    /// The most channels, over all tracks, whose presence in a mixed copy Shrink checks one by one: the
    /// check fits the copy against every channel at once, and its cost grows with their square.
    public static let mostCheckedChannels = 16

    /// One pass over a recording's tracks, read the way the mixer reads them (16 kHz, every channel apart),
    /// in step with a mono copy of it, measured per `MeetingStoragePlan.levelWindowSeconds` window. The app
    /// gathers it (`RecordingMixer.audit`); `firstFinding` judges it.
    public struct Audit: Sendable, Equatable {
        /// How many channels each track has, the tracks in order.
        public var trackChannels: [Int]
        /// The rate the tracks and the copy were read at.
        public var sampleRate: Double
        public var windows: [Window]

        public init(trackChannels: [Int], sampleRate: Double, windows: [Window]) {
            self.trackChannels = trackChannels
            self.sampleRate = sampleRate
            self.windows = windows
        }

        public struct Window: Sendable, Equatable {
            /// Frames of the copy in the window.
            public var frames: Double
            /// Σ xᵢxⱼ over every channel of every track (the tracks in order), row by row.
            public var gram: [Double]
            /// Σ xᵢc, each channel against the copy `c`.
            public var projection: [Double]
            /// Σ c².
            public var copySquares: Double

            public init(frames: Double, gram: [Double], projection: [Double], copySquares: Double) {
                self.frames = frames
                self.gram = gram
                self.projection = projection
                self.copySquares = copySquares
            }
        }
    }

    /// What `firstFinding` found wrong, with the window (`levelWindowSeconds` each) where it found it.
    /// Tracks and channels are numbered from 0, channels over all the tracks in order.
    public enum Finding: Sendable, Equatable {
        /// A channel the recording has (decoded as it is, at its own rate) came back much quieter, or
        /// not at all, when read for the mix.
        case channelNotRead(window: Int, channel: Int)
        /// A track's channels cancel when combined into its own signal: one channel in opposite polarity
        /// to another (the review's R2). The mix cannot hold that track's sound.
        case trackCancels(window: Int, track: Int)
        /// The copy is much quieter than the mix it was made from in a stretch: the encode lost it.
        case copyMissingSound(window: Int)
        /// The copy does not carry a track's own signal: lost by the mixer, or by the encode.
        case trackMissing(window: Int, track: Int)
        /// The copy does not carry a channel that sounds apart from the others: lost from its track.
        case channelMissing(window: Int, channel: Int)
        /// A track that sounds was never a large enough part of the copy to be measured in it, so its
        /// presence cannot be shown, and Shrink fails closed.
        case trackNeverMeasured(track: Int)
        /// More channels than `mostCheckedChannels`: not checked, so not shrunk.
        case tooManyChannels(count: Int)
    }

    /// How much of a track's own sound its combined signal must keep: a quarter of what channels that
    /// neither add nor cancel would give, measured as `Σᵢⱼ xᵢxⱼ / Σᵢ xᵢ²` over its channels — 1 for channels
    /// that do not correlate (two sides of a call on left and right, a silent channel), the channel count
    /// for identical ones, 0 for two in opposite polarity. Below a quarter, combining lost most of it.
    public static let minimumOwnMix = 0.25

    /// A track, or a channel, is measured in the copy only in a window where its expected share of the copy
    /// comes within this factor of the copy's energy (24 dB): quieter, the encode's noise and its masking of
    /// quiet sound under loud (which is how AAC saves bits) can swamp it. Measured through the real mix and
    /// encode (round 2 probes, `gates/r2-audit-probe.log` and `r2-audit-probe2.log`): speech and tones in
    /// the copy fit at 0.82 to 0.95 of what the mix gives them, also 15 and 23 dB under another track, and a
    /// track the mixer dropped fits within 0.015 of 0 at every level measured. White noise does not survive
    /// AAC as a waveform (0.009 to 0.89 at 15 dB down), so a noisy track that is measured can be judged
    /// missing — a refusal, the safe direction.
    public static let measurableShare = 1.0 / 256

    /// The least a measured track's fit may be, as a share of what the mix gives it. Tighter than the
    /// level band's quarter because a fit is not a level: a copy keeping one channel of a track whose other
    /// channels hear the same voice 15 dB down (a panel's microphones, in phase or 4 ms late) still fits the
    /// track at about half, where the real encode keeps speech and tones at 0.82 to 0.95 (round 2 probe).
    public static let minimumTrackFit = 0.6

    /// A channel is fitted on its own only where at least this share of its sound is its own — not also in
    /// the other channels (the same voice, bleeding into a neighbour's microphone) — or its fit is not
    /// determined. Its fit must then reach the level band's lower bound of what the mix gives it.
    public static let minimumDistinctShare = 0.25

    /// Windows shorter than this many seconds (the recording's last, cut short) are not judged: too few
    /// frames to fit, and the length check covers the copy's end.
    public static let minimumWindowSeconds = 0.5

    /// The first thing that shows the copy may not hold every track of the recording, or nil when
    /// nothing does (F942, review R2 and M8). The checks, each per window:
    ///
    /// - every channel `nativeChannelWindows` heard in the recording was read for the mix at no less
    ///   than a quarter of its level (`channelNotRead`);
    /// - every track that sounds keeps `minimumOwnMix` of its sound when its channels are combined
    ///   (`trackCancels`);
    /// - the copy keeps at least a quarter of the mix's level (`copyMissingSound`);
    /// - a least-squares fit of the copy onto the tracks' own signals gives every measurable track that
    ///   sounds at least `minimumTrackFit` of the mix's gain (`trackMissing`) — waveforms, not levels, so
    ///   a track lost under another one sounding at the same time is seen;
    /// - a fit onto every channel gives every measurable channel that sounds apart from the others at
    ///   least a quarter of what the mix gives it (`channelMissing`) — so is a channel lost beside others
    ///   sounding at the same time, which no level and no fit of the whole track can see;
    /// - and every track that sounds was measured in at least one window (`trackNeverMeasured`).
    ///
    /// "Sounds" means at least a tenth of `nativeLevel`, the recording's level over every channel, and
    /// above `MeetingStoragePlan.silenceLevel`, as for the other checks. A copy is the mix's gain times the
    /// sum of the tracks' own signals, each its channels combined by `channelWeight`, so each channel is
    /// expected in it at `gain × channelWeight`.
    public static func firstFinding(_ audit: Audit, nativeChannelWindows: [[Double]], nativeLevel: Double) -> Finding? {
        let channels = audit.trackChannels.reduce(0, +)
        if channels > mostCheckedChannels { return .tooManyChannels(count: channels) }
        let audible = Swift.max(MeetingStoragePlan.silenceLevel, nativeLevel / 10)
        let floor = MeetingStoragePlan.levelRatioBand.lowerBound
        let tracks = audit.trackChannels.count
        var trackOf: [Int] = []
        for (track, count) in audit.trackChannels.enumerated() { trackOf += repeatElement(track, count: count) }
        let weightOf = (0..<channels).map { channelWeight(channels: audit.trackChannels[trackOf[$0]]) }
        var sounded = [Bool](repeating: false, count: tracks)
        var measured = [Bool](repeating: false, count: tracks)
        let shortest = Swift.max(1, minimumWindowSeconds * audit.sampleRate)
        for (index, window) in audit.windows.enumerated() where window.frames >= shortest {
            guard window.gram.count == channels * channels, window.projection.count == channels else { continue }
            func rms(_ squares: Double) -> Double { (Swift.max(0, squares) / window.frames).squareRoot() }
            func g(_ i: Int, _ j: Int) -> Double { window.gram[i * channels + j] }
            // The reading kept every channel the recording has.
            for channel in 0..<channels where channel < nativeChannelWindows.count && index < nativeChannelWindows[channel].count {
                let native = nativeChannelWindows[channel][index]
                guard native.isFinite, native >= audible else { continue }
                guard rms(g(channel, channel)) >= native * floor else { return .channelNotRead(window: index, channel: channel) }
            }
            // The tracks' own signals: their Gram matrix and their fit against the copy.
            var trackGram = [Double](repeating: 0, count: tracks * tracks)
            var trackProjection = [Double](repeating: 0, count: tracks)
            var trackChannelEnergy = [Double](repeating: 0, count: tracks)
            var trackSum = [Double](repeating: 0, count: tracks)
            for i in 0..<channels {
                trackProjection[trackOf[i]] += weightOf[i] * window.projection[i]
                trackChannelEnergy[trackOf[i]] += g(i, i)
                for j in 0..<channels {
                    trackGram[trackOf[i] * tracks + trackOf[j]] += weightOf[i] * weightOf[j] * g(i, j)
                    if trackOf[i] == trackOf[j] { trackSum[trackOf[i]] += g(i, j) }
                }
            }
            // Each track that sounds keeps its sound when its channels are combined.
            var soundsHere = [Bool](repeating: false, count: tracks)
            for track in 0..<tracks {
                let energy = trackChannelEnergy[track]
                guard rms(energy / Double(audit.trackChannels[track])) >= audible else { continue }
                soundsHere[track] = true
                sounded[track] = true
                let ownMix = trackSum[track] / energy
                guard ownMix.isFinite, ownMix >= minimumOwnMix else { return .trackCancels(window: index, track: track) }
            }
            // The copy keeps the mix's level.
            let mixSquares = gain * gain * trackGram.reduce(0, +)
            if rms(mixSquares) >= audible, !(rms(window.copySquares) >= rms(mixSquares) * floor) {
                return .copyMissingSound(window: index)
            }
            // Each measurable track is in the copy.
            let trackFit = leastSquares(gram: trackGram, projection: trackProjection, size: tracks).solution
            for track in 0..<tracks where soundsHere[track] {
                let share = gain * gain * trackGram[track * tracks + track]
                guard share > 0, share >= window.copySquares * measurableShare else { continue }
                measured[track] = true
                guard trackFit[track].isFinite, trackFit[track] >= gain * minimumTrackFit else {
                    return .trackMissing(window: index, track: track)
                }
            }
            // And each channel that sounds apart from the others.
            let channelFit = leastSquares(gram: window.gram, projection: window.projection, size: channels)
            for channel in 0..<channels {
                let energy = g(channel, channel)
                guard energy > 0, rms(energy) >= audible else { continue }
                let own = channelFit.ownEnergy[channel]
                let expected = gain * weightOf[channel]
                guard own >= energy * minimumDistinctShare, expected * expected * own >= window.copySquares * measurableShare else {
                    continue
                }
                guard channelFit.solution[channel].isFinite, channelFit.solution[channel] >= expected * floor else {
                    return .channelMissing(window: index, channel: channel)
                }
            }
        }
        if let track = (0..<tracks).first(where: { sounded[$0] && !measured[$0] }) {
            return .trackNeverMeasured(track: track)
        }
        return nil
    }

    /// Solves `(G + λI) β = p` for the coefficients of a least-squares fit, `G` the regressors' Gram
    /// matrix, and returns them with each regressor's own energy — the part of it the others do not
    /// explain, `1 / (G + λI)⁻¹ᵢᵢ`, which is how well its coefficient is determined. The small ridge `λ`
    /// keeps the fit defined when two regressors hold the same sound (their coefficients then share it
    /// evenly, and neither has energy of its own) or one is silent (its coefficient is 0). Gauss–Jordan
    /// elimination with partial pivoting: the matrix is as small as the number of tracks or channels.
    static func leastSquares(gram: [Double], projection: [Double], size: Int) -> (solution: [Double], ownEnergy: [Double]) {
        let failed = ([Double](repeating: .nan, count: size), [Double](repeating: 0, count: size))
        guard size > 0, gram.count == size * size, projection.count == size else { return failed }
        let trace = (0..<size).reduce(0.0) { $0 + gram[$1 * size + $1] }
        let ridge = Swift.max(trace / Double(size) * 1e-9, 1e-15)
        // [A | I | p], reduced to [I | A⁻¹ | β].
        let width = 2 * size + 1
        var rows = [Double](repeating: 0, count: size * width)
        for i in 0..<size {
            for j in 0..<size { rows[i * width + j] = gram[i * size + j] + (i == j ? ridge : 0) }
            rows[i * width + size + i] = 1
            rows[i * width + 2 * size] = projection[i]
        }
        for column in 0..<size {
            var pivot = column
            for row in column..<size where abs(rows[row * width + column]) > abs(rows[pivot * width + column]) { pivot = row }
            if pivot != column { for k in 0..<width { rows.swapAt(column * width + k, pivot * width + k) } }
            let lead = rows[column * width + column]
            guard lead != 0, lead.isFinite else { return failed }
            for k in 0..<width { rows[column * width + k] /= lead }
            for row in 0..<size where row != column {
                let factor = rows[row * width + column]
                guard factor != 0 else { continue }
                for k in 0..<width { rows[row * width + k] -= factor * rows[column * width + k] }
            }
        }
        let solution = (0..<size).map { rows[$0 * width + 2 * size] }
        let ownEnergy = (0..<size).map { i -> Double in
            let inverse = rows[i * width + size + i]
            return inverse > 0 && inverse.isFinite ? 1 / inverse : 0
        }
        return (solution, ownEnergy)
    }
}
