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

    /// Silence no track holds that a mix may carry whatever the tracks hold: a minute, so short recordings
    /// whose tracks start a little apart are mixed as they are timed.
    public static let silenceAllowance: TimeInterval = 60

    /// The longest a mix may run for tracks that hold `heldSeconds` of audio between them — the media their
    /// edit lists map, not the range they claim: that audio, and as much silence again or
    /// `silenceAllowance`, whichever is more (second review of F942, N16). The tracks' time range is set by
    /// their edit lists, so bounding a buffer's time by it (`placementLimit`) cannot catch an edit list that
    /// places a track an hour in: a 108 KB file mixed into a 115 MB WAV. A mix longer than this is refused,
    /// so its size follows the audio the file holds, never a corrupt timestamp. Not a number counts as none.
    public static func longestMix(heldSeconds: TimeInterval) -> TimeInterval {
        let held = heldSeconds.isFinite ? Swift.max(0, heldSeconds) : 0
        return held + Swift.max(silenceAllowance, held)
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

    // MARK: - Showing that a copy holds every track (F942 review R2; F980)

    /// The most channels, over all tracks, whose presence in a mixed copy Shrink checks one by one: the
    /// check fits the copy against every channel at once, and its cost grows with their square.
    public static let mostCheckedChannels = 16

    /// The most frames a track's step with the copy may move from one audit window to the next, either
    /// way: 16, a millisecond at 16 kHz. AVAssetReader does not read an ffmpeg-made file the same way
    /// twice, and its reads drift (second review of F942, C3). Measured on files from ffmpeg 8.1.2 (F980,
    /// `gates/01-drift-probe.log`, `09-long-probe.log`): between one second and the next the lag of a track
    /// against the copy moves by at most 5 frames; over a file it is not bounded — in two reads of three it
    /// climbed steadily, about 0.4 frames a second (a 25 ppm rate difference in the converter), to 16 and
    /// past, each track on its own. So the audit follows each track: it searches this far either side of
    /// where the track stood in the window before (`alignment`), from 0 at the start. A copy out of step
    /// from the start by more than this is not shown to be in time with the recording, and is refused.
    public static let alignmentFrames = 16

    /// A track that sounded nothing the copy follows in a window (silence, say) keeps its place, and its
    /// search widens by `alignmentFrames` a window while that lasts, to this many frames at most: the drift
    /// goes on through its silence, and when it speaks again it must be found. 256 frames is 16 ms; at the
    /// measured rate that covers ten minutes of silence.
    public static let widestAlignment = 256

    /// The furthest a track may stand from the copy in all: 4,800 frames, 0.3 s. At the measured rate
    /// that is more than three hours of drift; a track further out of step than this is refused
    /// (`Finding.trackOutOfStep`) — the audit cannot tell such a copy from one timed wrongly.
    public static let alignmentReach = 4_800

    /// How long each window of the audit is, and the stretch each track is aligned to the copy over: a
    /// second, not the plain path's five (`MeetingStoragePlan.levelWindowSeconds`). Two reasons. The drift
    /// moves by a few frames a second (measured), so one lag per five seconds would leave part of a window
    /// out of step. And whether a track can be measured in the copy is judged against the copy's energy
    /// over the window (`measurableShare`), so a window dilutes a short sound by its share of the window: a
    /// tenth of a second of one voice 12 dB under another reads as 29 dB under over five seconds and 22 dB
    /// over one. What the fit can tell depends on the sound's own frames, not the window's length.
    public static let auditWindowSeconds: TimeInterval = 1

    /// One pass over a recording's tracks, read the way the mixer reads them (16 kHz, every channel apart),
    /// in step with a mono copy of it, measured per `auditWindowSeconds` window with each track aligned to
    /// the copy in each. The app gathers it (`RecordingMixer.audit`); `firstFinding` judges it.
    public struct Audit: Sendable, Equatable {
        /// How many channels each track has, the tracks in order.
        public var trackChannels: [Int]
        /// The rate the tracks and the copy were read at.
        public var sampleRate: Double
        public var windows: [Window]
        /// The first track that drifted past `alignmentReach` from the copy, and the window where: the
        /// audit stops following it there, and `firstFinding` refuses with `trackOutOfStep`. No track when
        /// the tracks were followed together, against the mix's own read (F998): the copy drifted.
        public var outOfStep: (window: Int, track: Int?)?

        public init(trackChannels: [Int], sampleRate: Double, windows: [Window], outOfStep: (window: Int, track: Int?)? = nil) {
            self.trackChannels = trackChannels
            self.sampleRate = sampleRate
            self.windows = windows
            self.outOfStep = outOfStep
        }

        public static func == (lhs: Audit, rhs: Audit) -> Bool {
            lhs.trackChannels == rhs.trackChannels && lhs.sampleRate == rhs.sampleRate && lhs.windows == rhs.windows
                && lhs.outOfStep?.window == rhs.outOfStep?.window && lhs.outOfStep?.track == rhs.outOfStep?.track
        }

        public struct Window: Sendable, Equatable {
            /// Frames of the copy in the window.
            public var frames: Double
            /// Σ xᵢxⱼ over every channel of every track (the tracks in order), row by row, each track's
            /// channels at the lag that aligns the track with the copy.
            public var gram: [Double]
            /// Σ xᵢc, each channel against the copy `c`, at the same lags.
            public var projection: [Double]
            /// Σ c².
            public var copySquares: Double
            /// The lag each track was aligned at (`alignment`), for the record; nothing is judged by it.
            public var lags: [Int]

            public init(frames: Double, gram: [Double], projection: [Double], copySquares: Double, lags: [Int] = []) {
                self.frames = frames
                self.gram = gram
                self.projection = projection
                self.copySquares = copySquares
                self.lags = lags
            }
        }
    }

    /// Per track, the step from where it stood at which the copy follows it in one window, or nil when the
    /// copy follows it nowhere there: silence, sound the copy does not hold, or sound too faint beside the
    /// copy's. Each channel's `projectionsByLag[channel]` holds its projections onto the copy at every lag
    /// from −s to s about the track's place, s being `(count − 1) / 2` — `alignmentFrames` as a rule, wider
    /// for a track found nowhere in the windows before (`widestAlignment`) — and `energiesByLag[channel]`
    /// its energy over the window shifted by each of those lags. The step is the lag where the sum over the
    /// track's channels is largest, the smaller lag on a tie; it counts as found only where that sum reaches
    /// `minimumFit` of what the mix gives the track there, `gain × channelWeight × Σ energies at that lag` —
    /// the fit a present track makes. Anything less is noise: a track silent in a window, searched widely,
    /// once found itself 123 frames on in a speck of a near-silent copy and pulled the next window's sound
    /// into this one (`gates/11-n9-probe.log`); measured against the energy at its place, which was none,
    /// the speck passed. A track the copy lost is never found, keeps its place, and fails its fit there,
    /// which is right. And what anchors the alignment must be a measurable part of the copy's energy in
    /// the window, `copySquares`, at `measurableShare` as the judgement measures it: the few onset frames of
    /// a track that starts at a window's end once found themselves, 38 frames early, in the copy's AAC
    /// pre-echo of that onset — a fine fit against their own tiny energy (`gates/18-shared-probe.log`) —
    /// and the track then stood 38 frames off where it really began.
    ///
    /// The channels of one track are decoded together, so they share a lag; the choice uses the whole
    /// track's sound, never one quiet channel's, so a channel the copy lacks cannot pick itself a
    /// flattering lag. A track in opposite polarity to the copy can: shifted until it looks a little like
    /// the copy, its cancellation no longer shows in the aligned sums — but then those sums hold far more
    /// sound than the copy, and the copy's level refuses it (`copyMissingSound`); where the aligned tracks
    /// still cancel, `tracksCancel` does. Either way the original is kept.
    public static func alignment(projectionsByLag: [[Double]], energiesByLag: [[Double]], copySquares: Double,
                                 trackChannels: [Int]) -> [Int?] {
        var first = 0
        return trackChannels.map { count -> Int? in
            defer { first += count }
            guard count > 0, first < projectionsByLag.count else { return nil }
            let span = (projectionsByLag[first].count - 1) / 2
            let expected = gain * channelWeight(channels: count)
            let least = expected * minimumFit
            var best: (lag: Int, value: Double)?
            for index in 0..<(2 * span + 1) {
                let lag = index - span
                var value = 0.0, energy = 0.0
                for channel in first..<(first + count) where channel < projectionsByLag.count && index < projectionsByLag[channel].count {
                    value += projectionsByLag[channel][index]
                    energy += channel < energiesByLag.count && index < energiesByLag[channel].count ? energiesByLag[channel][index] : 0
                }
                guard value.isFinite, energy.isFinite, energy > 0, value >= least * energy,
                      expected * expected * energy >= copySquares * measurableShare else { continue }
                if best == nil || value > best!.value || (value == best!.value && abs(lag) < abs(best!.lag)) { best = (lag, value) }
            }
            return best?.lag
        }
    }

    /// What `firstFinding` found wrong, with the window (`levelWindowSeconds` each) where it found it.
    /// Tracks and channels are numbered from 0, channels over all the tracks in order. Each is a reason the
    /// copy is not shown to hold every track and channel; Shrink then keeps the original.
    public enum Finding: Sendable, Equatable {
        /// A channel the recording has (decoded as it is, at its own rate) came back much quieter, or
        /// not at all, when read for the mix.
        case channelNotRead(window: Int, channel: Int)
        /// A measurement in this window is not a number: a channel of the recording holds NaN or
        /// infinity (D2), or, with `channel` nil, the copy does. Not sound, so not shown to be in a copy.
        case notANumber(window: Int, channel: Int?)
        /// A window whose sums do not match the recording's channel count: not measured, so not judged.
        case unreadableWindow(window: Int)
        /// A track drifted further from the copy than `alignmentReach`: the audit cannot tell the copy
        /// from one timed wrongly, so it stopped following the track there. With `track` nil, every track
        /// together: the copy drifted from the mix's own read (F998).
        case trackOutOfStep(window: Int, track: Int?)
        /// A track's channels cancel when combined into its own signal: one channel in opposite polarity
        /// to another (the review's R2). The mix cannot hold that track's sound.
        case trackCancels(window: Int, track: Int)
        /// The tracks cancel one another when summed: a whole track in opposite polarity to another. The
        /// mix holds a fraction of their sound, or none.
        case tracksCancel(window: Int)
        /// The copy is much quieter than the mix it was made from in a stretch: the encode lost it.
        case copyMissingSound(window: Int)
        /// The copy's waveform does not follow the mix's in a stretch, or is much louder than it: what the
        /// copy holds there is not the recording.
        case copyUnlikeMix(window: Int)
        /// The copy does not carry a track's own signal: lost by the mixer, or by the encode.
        case trackMissing(window: Int, track: Int)
        /// A track sounds in this stretch but is too quiet beside the others for its presence in the copy to
        /// be measured (F978): not shown, so not deleted.
        case trackMasked(window: Int, track: Int)
        /// The copy does not carry a channel that sounds apart from the others: lost from its track.
        case channelMissing(window: Int, channel: Int)
        /// A channel sounds apart from the others in this stretch but is too quiet beside them to be
        /// measured in the copy (F978): not shown, so not deleted.
        case channelMasked(window: Int, channel: Int)
        /// More channels than `mostCheckedChannels`: not checked, so not shrunk.
        case tooManyChannels(count: Int)
    }

    /// What counts as sounding: at least this share of the level the same track or channel has over the
    /// whole recording (a tenth, 20 dB), and above `MeetingStoragePlan.silenceLevel`. Relative to its own
    /// level and not the recording's, because a quiet track under a tenth of the recording's level was judged
    /// nowhere, and the real mixer cancelled it where it sounded alone (second review of F942, D1); relative
    /// to its own level and not an absolute floor, because a microphone's room tone, 30 dB under its voice,
    /// is not sound a copy must be shown to hold.
    public static let audibleShare = 0.1

    /// How much of a track's own sound its combined signal must keep: a quarter of what channels that
    /// neither add nor cancel would give, measured as `Σᵢⱼ xᵢxⱼ / Σᵢ xᵢ²` over its channels — 1 for channels
    /// that do not correlate (two sides of a call on left and right, a silent channel), the channel count
    /// for identical ones, 0 for two in opposite polarity. Below a quarter, combining lost most of it. The
    /// same bound judges the tracks' sum against the tracks (`tracksCancel`).
    public static let minimumOwnMix = 0.25

    /// A track, or a channel, is measured in the copy only in a window where its own share of the copy —
    /// the part the other tracks and channels do not also hold, at the level the mix gives it — comes within
    /// this factor of the copy's energy (24 dB). Measured through the real mix and a 32 kbps AAC encode on
    /// speech under speech (F980, `gates/01-drift-probe.log`): 20 dB under, a present track fits at 0.94 to
    /// 1.00 and a dropped one within 0.14 of 0; 24 dB under, 0.92 to 1.16 against at most 0.24; 30 dB under,
    /// a dropped track once fitted at 0.57, which `minimumFit` cannot tell from present. So a track that
    /// sounds but is quieter than this beside the others is not measured, and the window is refused
    /// (`trackMasked`): the copy cannot be shown to hold it there.
    public static let measurableShare = 1.0 / 256

    /// The least a measured track's, channel's or mix's fit may be, as a share of what the mix gives it.
    /// Tighter than the level band's quarter because a fit is not a level: a copy keeping one channel of a
    /// track whose other channels hear the same voice 15 dB down (a panel's microphones, in phase or 4 ms
    /// late) still fits the track at about half, where the real encode keeps speech and tones at 0.82 to
    /// 1.00 (round 2 probe; the measurement under `measurableShare`).
    public static let minimumFit = 0.6

    /// A track or a channel is fitted on its own only where at least this share of its energy is its own —
    /// not also in the others (the same voice on two tracks, or bleeding into a neighbour's microphone) — or
    /// its coefficient is not determined, and the encode's noise decided it (second review of F942, C4:
    /// identical tracks, OBS's master beside its stems). Sound it shares with the others is proven as the
    /// sum it is heard in, by the fit of the whole mix (`copyUnlikeMix`).
    public static let minimumDistinctShare = 0.25

    /// The first thing that shows the copy may not hold every track and channel of the recording, or nil
    /// when nothing does (F942 review R2 and M8; F980). Every window is judged, the recording's last partial
    /// one and a recording shorter than a window included. The checks, each per window:
    ///
    /// - nothing measured is NaN or infinite, in the recording's own decode, the audit's reading or the
    ///   copy (`notANumber`);
    /// - every channel the recording's own decode hears was read for the mix at no less than a quarter of
    ///   its level (`channelNotRead`);
    /// - every track that sounds keeps `minimumOwnMix` of its sound when its channels are combined
    ///   (`trackCancels`), and the tracks keep as much when summed (`tracksCancel`);
    /// - the copy keeps the mix's level within `MeetingStoragePlan.levelRatioBand` (`copyMissingSound`,
    ///   `copyUnlikeMix`) and follows its waveform at `minimumFit` of the mix's gain (`copyUnlikeMix`);
    /// - a least-squares fit of the copy onto the tracks' own signals gives every track that sounds and
    ///   whose sound is its own at least `minimumFit` of the gain where it is measurable (`trackMissing`),
    ///   and refuses the window where it is not (`trackMasked`) — waveforms, not levels, so a track lost
    ///   under another one sounding at the same time is seen;
    /// - the same, channel by channel (`channelMissing`, `channelMasked`), so a channel lost beside others
    ///   sounding at once is seen, which no fit of the whole track can show.
    ///
    /// "Sounds" is `audibleShare` of the same track's or channel's level over the whole recording, above
    /// `MeetingStoragePlan.silenceLevel`. A copy is the mix's gain times the sum of the tracks' own signals,
    /// each its channels combined by `channelWeight`, so each channel is expected in it at `gain ×
    /// channelWeight`. `nativeLevel` is the recording's level over every channel from its own decode;
    /// not a number, it refuses.
    public static func firstFinding(_ audit: Audit, nativeChannelWindows: [[Double]], nativeLevel: Double) -> Finding? {
        let channels = audit.trackChannels.reduce(0, +)
        if channels > mostCheckedChannels { return .tooManyChannels(count: channels) }
        let tracks = audit.trackChannels.count
        var trackOf: [Int] = []
        for (track, count) in audit.trackChannels.enumerated() { trackOf += repeatElement(track, count: count) }
        let weightOf = (0..<channels).map { channelWeight(channels: audit.trackChannels[trackOf[$0]]) }
        let band = MeetingStoragePlan.levelRatioBand
        func floor(_ level: Double) -> Double { Swift.max(MeetingStoragePlan.silenceLevel, level * audibleShare) }

        // Nothing that is not a number is sound, and nothing can be shown about it.
        for (channel, levels) in nativeChannelWindows.enumerated() {
            if let window = levels.firstIndex(where: { !$0.isFinite }) { return .notANumber(window: window, channel: channel) }
        }
        guard nativeLevel.isFinite else { return .notANumber(window: 0, channel: nil) }
        if let out = audit.outOfStep { return .trackOutOfStep(window: out.window, track: out.track) }
        for (index, window) in audit.windows.enumerated() {
            guard window.frames.isFinite, window.gram.count == channels * channels, window.projection.count == channels else {
                return .unreadableWindow(window: index)
            }
            guard window.copySquares.isFinite else { return .notANumber(window: index, channel: nil) }
            for channel in 0..<channels where !window.gram[channel * channels + channel].isFinite || !window.projection[channel].isFinite {
                return .notANumber(window: index, channel: channel)
            }
            if let bad = window.gram.firstIndex(where: { !$0.isFinite }) { return .notANumber(window: index, channel: bad / channels) }
        }

        func trackSums(_ window: Audit.Window) -> TrackSums {
            Self.trackSums(gram: window.gram, projection: window.projection, trackChannels: audit.trackChannels)
        }

        // Each track's, channel's and the mix's level over the whole recording, which "sounds" is relative to.
        var totalFrames = 0.0
        var channelEnergy = [Double](repeating: 0, count: channels)
        var trackSignalEnergy = [Double](repeating: 0, count: tracks)
        var trackChannelEnergy = [Double](repeating: 0, count: tracks)
        var tracksSumEnergy = 0.0, mixEnergy = 0.0
        for window in audit.windows {
            totalFrames += window.frames
            for channel in 0..<channels { channelEnergy[channel] += window.gram[channel * channels + channel] }
            let sums = trackSums(window)
            for track in 0..<tracks {
                trackSignalEnergy[track] += sums.gram[track * tracks + track]
                trackChannelEnergy[track] += sums.channelEnergy[track]
                tracksSumEnergy += sums.gram[track * tracks + track]
            }
            mixEnergy += sums.gram.reduce(0, +)
        }
        func overall(_ energy: Double, _ count: Double = 1) -> Double { totalFrames > 0 ? (Swift.max(0, energy) / (totalFrames * count)).squareRoot() : 0 }
        let channelFloor = channelEnergy.map { floor(overall($0)) }
        let trackSignalFloor = trackSignalEnergy.map { floor(overall($0)) }
        let trackChannelFloor = (0..<tracks).map { floor(overall(trackChannelEnergy[$0], Double(audit.trackChannels[$0]))) }
        let tracksSumFloor = floor(overall(tracksSumEnergy))
        let mixFloor = floor(gain * overall(mixEnergy))
        let nativeFloor = nativeChannelWindows.map { levels -> Double in
            floor(levels.isEmpty ? 0 : (levels.reduce(0) { $0 + $1 * $1 } / Double(levels.count)).squareRoot())
        }

        // The reading kept every channel the recording has: the recording's own decode measures each
        // channel per `MeetingStoragePlan.levelWindowSeconds`, so the audit's windows are summed per that
        // stretch to compare, and a finding names the stretch's first audit window.
        let perNative = Swift.max(1, Int(saturating: (MeetingStoragePlan.levelWindowSeconds / auditWindowSeconds).rounded()))
        var readEnergy: [[Double]] = [], readFrames: [Double] = []
        for (index, window) in audit.windows.enumerated() {
            let group = index / perNative
            while readEnergy.count <= group { readEnergy.append([Double](repeating: 0, count: channels)); readFrames.append(0) }
            readFrames[group] += window.frames
            for channel in 0..<channels { readEnergy[group][channel] += window.gram[channel * channels + channel] }
        }
        for (group, frames) in readFrames.enumerated() where frames > 0 {
            for channel in 0..<channels where channel < nativeChannelWindows.count && group < nativeChannelWindows[channel].count {
                let native = nativeChannelWindows[channel][group]
                guard native >= nativeFloor[channel] else { continue }
                guard (readEnergy[group][channel] / frames).squareRoot() >= native * band.lowerBound else {
                    return .channelNotRead(window: group * perNative, channel: channel)
                }
            }
        }

        for (index, window) in audit.windows.enumerated() where window.frames > 0 {
            func rms(_ squares: Double) -> Double { (Swift.max(0, squares) / window.frames).squareRoot() }
            func g(_ i: Int, _ j: Int) -> Double { window.gram[i * channels + j] }
            let sums = trackSums(window)
            // Each track that sounds keeps its sound when its channels are combined.
            for track in 0..<tracks {
                let energy = sums.channelEnergy[track]
                guard rms(energy / Double(audit.trackChannels[track])) >= trackChannelFloor[track] else { continue }
                let ownMix = sums.sum[track] / energy
                guard ownMix.isFinite, ownMix >= minimumOwnMix else { return .trackCancels(window: index, track: track) }
            }
            // And the tracks keep theirs when summed.
            let mixHere = sums.gram.reduce(0, +)
            let tracksSumHere = (0..<tracks).reduce(0.0) { $0 + sums.gram[$1 * tracks + $1] }
            if rms(tracksSumHere) >= tracksSumFloor, !(mixHere >= tracksSumHere * minimumOwnMix) {
                return .tracksCancel(window: index)
            }
            // The copy keeps the mix's level, and follows its waveform.
            let mixSquares = gain * gain * mixHere
            if rms(mixSquares) >= mixFloor {
                let ratio = rms(window.copySquares) / rms(mixSquares)
                guard ratio >= band.lowerBound else { return .copyMissingSound(window: index) }
                let mixFit = (0..<channels).reduce(0.0) { $0 + weightOf[$1] * window.projection[$1] } / mixHere
                guard ratio <= band.upperBound, mixFit.isFinite, mixFit >= gain * minimumFit else { return .copyUnlikeMix(window: index) }
            }
            // Each track that sounds, and whose sound is its own, is in the copy where it can be measured.
            let trackFit = leastSquares(gram: sums.gram, projection: sums.projection, size: tracks)
            for track in 0..<tracks {
                let energy = sums.gram[track * tracks + track]
                guard rms(energy) >= trackSignalFloor[track] else { continue }
                let own = trackFit.ownEnergy[track]
                guard own >= energy * minimumDistinctShare else { continue }
                guard gain * gain * own >= window.copySquares * measurableShare else { return .trackMasked(window: index, track: track) }
                guard trackFit.solution[track].isFinite, trackFit.solution[track] >= gain * minimumFit else {
                    return .trackMissing(window: index, track: track)
                }
            }
            // And each channel that sounds apart from the others.
            let channelFit = leastSquares(gram: window.gram, projection: window.projection, size: channels)
            for channel in 0..<channels {
                let energy = g(channel, channel)
                guard rms(energy) >= channelFloor[channel] else { continue }
                let own = channelFit.ownEnergy[channel]
                guard own >= energy * minimumDistinctShare else { continue }
                let expected = gain * weightOf[channel]
                guard expected * expected * own >= window.copySquares * measurableShare else {
                    return .channelMasked(window: index, channel: channel)
                }
                guard channelFit.solution[channel].isFinite, channelFit.solution[channel] >= expected * minimumFit else {
                    return .channelMissing(window: index, channel: channel)
                }
            }
        }
        return nil
    }

    /// The tracks' own signals in one window: their Gram matrix and projection (each track's channels
    /// combined by `channelWeight`), each track's channels' energy, and the energy of its channels' sum.
    struct TrackSums {
        var gram: [Double], projection: [Double], channelEnergy: [Double], sum: [Double]
    }

    static func trackSums(gram: [Double], projection: [Double], trackChannels: [Int]) -> TrackSums {
        let channels = trackChannels.reduce(0, +), tracks = trackChannels.count
        var trackOf: [Int] = []
        for (track, count) in trackChannels.enumerated() { trackOf += repeatElement(track, count: count) }
        var sums = TrackSums(gram: [Double](repeating: 0, count: tracks * tracks), projection: [Double](repeating: 0, count: tracks),
                             channelEnergy: [Double](repeating: 0, count: tracks), sum: [Double](repeating: 0, count: tracks))
        guard gram.count == channels * channels, projection.count == channels else { return sums }
        for i in 0..<channels {
            let wi = channelWeight(channels: trackChannels[trackOf[i]])
            sums.projection[trackOf[i]] += wi * projection[i]
            sums.channelEnergy[trackOf[i]] += gram[i * channels + i]
            for j in 0..<channels {
                let g = gram[i * channels + j]
                sums.gram[trackOf[i] * tracks + trackOf[j]] += wi * channelWeight(channels: trackChannels[trackOf[j]]) * g
                if trackOf[i] == trackOf[j] { sums.sum[trackOf[i]] += g }
            }
        }
        return sums
    }

    /// The coefficient the copy gives each track's own signal in one window, from a least-squares fit onto
    /// every track at once — `gain` for a track the copy holds as the mix made it — and how much of the
    /// copy's energy that fit explains, so the app can take each track out of the copy, align the others
    /// against what remains, and keep the alignment that explains the copy best (`RecordingMixer.audit`).
    /// NaN coefficients and nothing explained where the sums do not match the tracks.
    public static func trackFit(gram: [Double], projection: [Double], trackChannels: [Int]) -> (coefficients: [Double], explained: Double) {
        let channels = trackChannels.reduce(0, +), tracks = trackChannels.count
        guard gram.count == channels * channels, projection.count == channels else {
            return ([Double](repeating: .nan, count: tracks), 0)
        }
        let sums = trackSums(gram: gram, projection: projection, trackChannels: trackChannels)
        let fit = leastSquares(gram: sums.gram, projection: sums.projection, size: tracks)
        let explained = zip(fit.solution, sums.projection).reduce(0.0) { $0 + $1.0 * $1.1 }
        return (fit.solution, explained.isFinite ? explained : 0)
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
