import Foundation

// MARK: - Showing that a mono copy holds both channels of a two-channel recording (F1001)

extension RecordingMixPlan {
    /// What Shrink measures of a two-channel recording before it deletes it (F1001), in two links: whether the
    /// channels cancel each other when they are mixed into one, and whether the copy holds the mix. The app
    /// gathers it (`RecordingMixer.channelPresence`), reading the recording at 16 kHz, each channel apart, in
    /// step with the copy; `firstChannelNotInCopy` judges it.
    ///
    /// **The user's decision (2026-10-15): "Refuse any with cancellation".** A stereo recording whose channels
    /// noticeably cancel when mixed into one is kept full size, with a reason; no stereo copies. A mono copy
    /// cannot hold a voice that is in opposite polarity on the two channels (mid/side: left A + B, right A − B
    /// mixes to A), and over a stretch such channels' sums look exactly like two independent voices' (the
    /// review of Wave 7 lane S, X2), so the cancellation is looked for frequency by frequency, stretch by
    /// stretch, band by band (`stretches`).
    public struct ChannelPresence: Sendable, Equatable {
        /// How many channels the recording was read with.
        public var channels: Int
        /// The channels' cancellation, one entry per `cancellationGroupFrames` frames of
        /// `cancellationFrameSeconds`, in order.
        public var stretches: [Stretch]
        /// Per `MeetingStoragePlan.levelWindowSeconds` window: the mix's energy in `presenceBand`, and the part
        /// of it in bins the copy does not hold.
        public var mix: [Measure]
        /// Per window, per channel: the channel's energy in `presenceBand`, and the part of it in bins the
        /// channels' mix does not hold — F1001's first-round link, kept beside `stretches` (round 4,
        /// `mostChannelMissingShare`).
        public var channelWindows: [[Measure]]

        public struct Measure: Sendable, Equatable {
            public var energy: Double
            public var missing: Double

            public init(energy: Double, missing: Double) {
                self.energy = energy
                self.missing = missing
            }
        }

        public struct Stretch: Sendable, Equatable {
            /// Where it starts in the recording.
            public var start: TimeInterval
            /// The RMS of both channels' samples over it, on the 0…1 scale `MeetingStoragePlan.silenceLevel` uses.
            public var level: Double
            /// Per band of `cancellationBands`: the channels' energy there (the mean of the two), and the part
            /// of it that cancels in the mix — in bins where the channels are in opposite polarity,
            /// consistently (`cancels`).
            public var bands: [Measure]

            public init(start: TimeInterval, level: Double, bands: [Measure]) {
                self.start = start
                self.level = level
                self.bands = bands
            }
        }

        public init(channels: Int, stretches: [Stretch], mix: [Measure], channelWindows: [[Measure]]) {
            self.channels = channels
            self.stretches = stretches
            self.mix = mix
            self.channelWindows = channelWindows
        }
    }

    // MARK: Link 1 — do the channels cancel in the mix?

    /// Each frame of the cancellation measure: 1,024 frames at 16 kHz, 64 ms, a bin every 15.6 Hz, Hann
    /// windows half-overlapping. Short, so that a stretch holds many frames: whether a bin's opposite polarity
    /// is consistent is judged across them (`cancellationMinimumCoherence`).
    public static let cancellationFrameSeconds: TimeInterval = 0.064

    /// How many frames make a stretch: sixteen, 0.512 s. A stretch is judged on its own, against its own level,
    /// so a side voice that speaks alone for a little over half a second is a whole stretch of cancellation
    /// wherever it falls; and a loud stretch elsewhere hides nothing (review 2 of F1001, F2-3).
    public static let cancellationGroupFrames = 16

    /// The bands each stretch is judged in, by their edges in hertz: speech and above, to just under the 8 kHz
    /// the copy keeps. A cancellation confined to part of the spectrum (a side voice's lows, or its highs) is a
    /// large share of its own band even when it is a small share of the whole (review 1, partial-band probes).
    public static let cancellationBands: [Double] = [80, 250, 500, 1_000, 2_000, 4_000, 7_800]

    /// A band is judged in a stretch only where it holds at least this share of the stretch's energy: a
    /// band holding almost nothing has nothing a listener would miss.
    public static let judgedBandShare = 0.05

    /// A bin counts as cancelling only where the channels' cross-spectrum over the stretch is at least this
    /// coherent, `|Σ L·conj(R)|² / (Σ|L|² Σ|R|²)`: a voice in opposite polarity on the two channels is opposite
    /// in every frame (1), while two independent voices' harmonics drift past each other and are opposite only
    /// for a moment, so their coherence over a stretch is low.
    public static let cancellationMinimumCoherence = 0.7

    /// And only where its energy is spread over at least this many frames, `(Σ|L||R|)² / Σ|L|²|R|²`: in one
    /// frame any two sounds look coherent.
    public static let cancellationMinimumFrames = 3.0

    /// The channels of two microphones apart hear one voice a little late on one side: a comb filter, not a
    /// cancellation of a voice, which mixing loses nothing of that a listener misses. So before the polarity
    /// of each bin is read, the stretch's cross-correlation is searched up to this far either way — 3 ms, a
    /// metre between microphones, at 16 kHz 48 frames — and each bin is read at whichever of the lag 0 and
    /// the strongest `alignmentCandidates` lags (each at least `alignmentMinimumCorrelation`) makes it least
    /// opposite. A phone's or a laptop's two microphones are well inside it.
    public static let alignmentFrames16k = 48

    /// See `alignmentFrames16k`.
    public static let alignmentCandidates = 2

    /// See `alignmentFrames16k`: the normalized cross-correlation a lag must reach to be one of the delays the
    /// stretch's sound arrives with.
    public static let alignmentMinimumCorrelation = 0.3

    /// The most of a judged band's energy in a stretch that may cancel before the recording is kept: a tenth.
    /// Measured on the reviews' probes and the controls (F1001 round 2: offline, `gates/r2-03-harness.txt`;
    /// through Shrink, `r2-06-review1-probe-lines.txt`, `r2-06-review-probes.log`): every probe the reviews
    /// made reads from 0.25 up — tones mid/side with the side voice 6 dB down 0.25 (10 dB down, offline, 0.11);
    /// speech mid/side talking over each other throughout, every pairing tried, 0.27 to 0.72, and offline 0.23
    /// with the side voice 10 dB down; a 0.6 s side interjection 0.30; a side voice cancelling only below 1 kHz,
    /// only from 2 kHz or only above 4 kHz, 0.54 to 0.59 — while ordinary stereo reads at
    /// most 0.04: a voice per channel, one silent channel, identical, panned or correlated channels, DC or
    /// hiss on a silent channel, clipping, noise, a phone's spacing with one or two talkers. What it refuses
    /// that a listener might call ordinary: two talkers before a pair of microphones 0.75 to 1.5 ms apart (five
    /// of the six such fixtures, echoing or not, read 0.26 to 0.70), and a Haas widening of 10–20 ms (0.18 to
    /// 0.49) — both do lose sound to the mix's comb filter. A side voice more than about 10 dB under the middle
    /// one, talking over it throughout, is not caught.
    public static let mostCancelledShare = 0.1

    /// Whether a bin whose channels' cross-spectrum over a stretch, at its best alignment, has real part
    /// `alignedReal` (negative: opposite polarity), coherence `coherence` and energy spread over `frames`
    /// frames, cancels in the mix — and how much: `-alignedReal`, or 0. Not a number cancels nothing here; the
    /// stretch's energy then is not a number and `firstChannelNotInCopy` refuses on that.
    public static func cancels(alignedReal: Double, coherence: Double, frames: Double) -> Double {
        guard alignedReal.isFinite, coherence.isFinite, frames.isFinite, alignedReal < 0,
              coherence >= cancellationMinimumCoherence, frames >= cancellationMinimumFrames else { return 0 }
        return -alignedReal
    }

    // MARK: Beside link 1 — the first round's channel against the mix

    /// The most of a channel's energy in a `levelWindowSeconds` window, in `presenceBand`, that may lie in bins
    /// where the channels' mix does not hold it (`soundFound` at the channel's weight in the mix) — F1001's
    /// first-round link, kept as a refusal beside link 1 because each misses what the other catches (round 4;
    /// AGENTS.md: prefer two checks with different blind spots, the new one additional, not replacing). Link 1's
    /// spaced-microphone allowance reads a steady tone inverted on one channel as one delayed half a period —
    /// the same signal, which the mix cancels — so a loud inverted tone or odd-harmonic buzz read 0.000 and was
    /// deleted, as were a side voice under a talker on microphones 2.5–3 ms apart and a 0.1 s file (review 1 of
    /// round 2, 16 probes round 1 kept); this link has no allowance and, over five seconds, needs no three
    /// frames' spread. A quarter, as round 1 measured it (its ordinary stereo read at most 0.16; an echo-free
    /// pair a metre apart, 0.34, is refused).
    public static let mostChannelMissingShare = 0.25

    // MARK: Link 2 — does the copy hold the mix?

    /// Each frame of the copy's measure against the mix: 4,096 frames at 16 kHz, 256 ms, a bin every 3.9 Hz.
    /// Long, so a copy out of step with the recording by a few hundred frames (an encoder's priming, a reader's
    /// rounding) shares most of each frame with it.
    public static let presenceFrameSeconds: TimeInterval = 0.256

    /// How many of those frames each bin's projection is summed over: four, about half a second.
    public static let presenceGroupFrames = 4

    /// The frequencies the copy is measured in: 80 Hz to 4 kHz, where speech has nearly all its energy.
    public static let presenceBand: ClosedRange<Double> = 80...4_000

    /// A bin of the mix is held by the copy where the copy's projection onto it, `|Σ copy · conj(mix)|`,
    /// reaches this share of the mix's energy there — 12 dB under. The copy is the mix as the encode makes it.
    public static let presenceShare = 0.25

    /// The most of the mix's energy in a window that may lie in bins the copy does not hold: a twentieth.
    /// Measured: every good copy reads 0.003 at most (F1001, `gates/10-measure-final.txt`); a copy of the left
    /// channel alone of two independent voices reads 0.12 to 0.5, and a copy that kept a 12 dB quieter channel
    /// out, 0.06 (review 1's centre-and-LFE probe). It holds the mix only where the dropped channel is more
    /// than a twentieth of the mix's energy: a copy that keeps one channel is caught only then.
    public static let mostCopyMissingShare = 0.05

    /// Whether a bin with `energy`, expected in the copy at `weight`, onto which the copy projects
    /// `projection`, is held (`presenceShare`). No energy is nothing to hold, and is held. Not a number is not
    /// held.
    public static func soundFound(projection: Double, energy: Double, weight: Double) -> Bool {
        guard projection.isFinite, energy.isFinite, weight.isFinite else { return false }
        guard energy > 0 else { return true }
        return projection >= presenceShare * weight * energy
    }

    // MARK: The judgement

    /// Why a copy is not shown to hold both channels of a two-channel recording (F1001).
    public enum ChannelPresenceFinding: Sendable, Equatable {
        /// The channels cancel each other when mixed into one: more than `mostCancelledShare` of a judged
        /// band's energy in the stretch starting at `seconds`. `band` indexes `cancellationBands`.
        case cancels(seconds: TimeInterval, band: Int)
        /// More than `mostChannelMissingShare` of a channel's sound in this `levelWindowSeconds` window is not in
        /// the channels' mix: it cancels against the other channel (the first round's link, round 4).
        case missing(window: Int, channel: Int)
        /// More than `mostCopyMissingShare` of the mix's sound in this `levelWindowSeconds` window is not in the copy.
        case copyMissing(window: Int)
        /// Something that sounds was not measured, or a measure is not a number: not shown, so not deleted.
        /// `window` is a `levelWindowSeconds` window; `channel` the channel, when one is to blame.
        case unmeasured(window: Int, channel: Int?)
    }

    /// The first thing that shows the copy may not hold both channels, or nil (F1001):
    ///
    /// - the measure has two channels, as the recording's own decode does (`nativeChannelWindows`, per
    ///   `MeetingStoragePlan.levelWindowSeconds`), and nothing in either is not a number;
    /// - every window in which either channel's own decode is above `MeetingStoragePlan.silenceLevel` has
    ///   stretches measured in it;
    /// - in every stretch above `silenceLevel`, judged against its own energy and no one else's, no band holding
    ///   at least `judgedBandShare` of it has more than `mostCancelledShare` cancelling;
    /// - beside that, in every window in which a channel sounds (`audibleShare` of its own level), no more than
    ///   `mostChannelMissingShare` of that channel is missing from the mix (the first round's link, round 4);
    /// - and in every window in which a channel sounds (`audibleShare` of its own level), no more than
    ///   `mostCopyMissingShare` of the mix is missing from the copy.
    public static func firstChannelNotInCopy(_ presence: ChannelPresence,
                                             nativeChannelWindows: [[Double]]) -> ChannelPresenceFinding? {
        guard presence.channels == 2, nativeChannelWindows.count == 2 else { return .unmeasured(window: 0, channel: nil) }
        for (channel, levels) in nativeChannelWindows.enumerated() {
            if let window = levels.firstIndex(where: { !$0.isFinite }) { return .unmeasured(window: window, channel: channel) }
        }
        func valid(_ measure: ChannelPresence.Measure) -> Bool {
            measure.energy.isFinite && measure.missing.isFinite && measure.energy >= 0 && measure.missing >= 0
        }
        let window = MeetingStoragePlan.levelWindowSeconds
        func windowOf(_ seconds: TimeInterval) -> Int { Int(saturating: (seconds / window).rounded(.down)) }
        // Every window that sounds was measured: a stretch covers each window it overlaps.
        let span = Double(cancellationGroupFrames) * cancellationFrameSeconds / 2
        var measured = Set<Int>()
        for stretch in presence.stretches where stretch.start.isFinite && stretch.start >= 0 {
            let first = windowOf(stretch.start), last = windowOf(stretch.start + span * 0.999)
            if last >= first { for index in first...last { measured.insert(index) } }
        }
        let windows = nativeChannelWindows.map(\.count).max() ?? 0
        for index in 0..<windows where !measured.contains(index) {
            if nativeChannelWindows.contains(where: { index < $0.count && $0[index] >= MeetingStoragePlan.silenceLevel }) {
                return .unmeasured(window: index, channel: nil)
            }
        }
        // The channels do not cancel, stretch by stretch, band by band.
        for stretch in presence.stretches {
            guard stretch.start.isFinite, stretch.level.isFinite, stretch.bands.count == cancellationBands.count - 1,
                  stretch.bands.allSatisfy(valid) else {
                return .unmeasured(window: stretch.start.isFinite ? Swift.max(0, windowOf(stretch.start)) : 0, channel: nil)
            }
            guard stretch.level >= MeetingStoragePlan.silenceLevel else { continue }
            let total = stretch.bands.reduce(0) { $0 + $1.energy }
            for (band, measure) in stretch.bands.enumerated() where measure.energy > 0 && measure.energy >= judgedBandShare * total {
                if !(measure.missing <= measure.energy * mostCancelledShare) {
                    return .cancels(seconds: stretch.start, band: band)
                }
            }
        }
        // A channel "sounds" in a window at `audibleShare` of its own level over the whole recording, as F1001's
        // first round measured it, for the two window-level links below.
        let floors = nativeChannelWindows.map { levels in
            Swift.max(MeetingStoragePlan.silenceLevel, audibleShare
                * (levels.isEmpty ? 0 : (levels.reduce(0) { $0 + $1 * $1 } / Double(levels.count)).squareRoot()))
        }
        // Beside link 1, the first round's link: each sounding channel is in the mix (round 4).
        for index in 0..<windows {
            for channel in 0..<2 where index < nativeChannelWindows[channel].count && nativeChannelWindows[channel][index] >= floors[channel] {
                guard index < presence.channelWindows.count, presence.channelWindows[index].count == 2,
                      valid(presence.channelWindows[index][channel]) else {
                    return .unmeasured(window: index, channel: channel)
                }
                let measure = presence.channelWindows[index][channel]
                if measure.energy > 0, !(measure.missing <= measure.energy * mostChannelMissingShare) {
                    return .missing(window: index, channel: channel)
                }
            }
        }
        // And the copy holds the mix, in every window where a channel sounds: a near-silent tail is the encoder's.
        for (index, measure) in presence.mix.enumerated() {
            guard valid(measure) else { return .unmeasured(window: index, channel: nil) }
            let sounds = nativeChannelWindows.indices.contains { index < nativeChannelWindows[$0].count && nativeChannelWindows[$0][index] >= floors[$0] }
            if sounds, measure.energy > 0, !(measure.missing <= measure.energy * mostCopyMissingShare) { return .copyMissing(window: index) }
        }
        return nil
    }
}
