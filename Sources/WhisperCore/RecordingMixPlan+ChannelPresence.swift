import Foundation

// MARK: - Showing that a mono copy holds each channel of a two-channel recording (F1001)

extension RecordingMixPlan {
    /// How much of each channel's sound the channels' mono mix holds, and how much of the mix's sound the
    /// copy holds, measured per `MeetingStoragePlan.levelWindowSeconds` window (F1001). The app gathers it
    /// (`RecordingMixer.channelPresence`): it reads the recording at 16 kHz, each channel apart, in step with
    /// the copy, in `presenceFrameSeconds` frames, and forms the mix as the encode does, each channel at
    /// `channelWeight`. For every frequency bin in `presenceBand`, summed over `presenceGroupFrames` frames, it
    /// takes each channel's energy and the mix's projection onto it, `|Σ mix · conj(channel)|`, and the mix's
    /// energy and the copy's projection onto it. A bin where a projection is under `presenceShare` of what is
    /// expected (`soundFound`) holds sound the mix, or the copy, does not: its energy is `missing`.
    /// `firstChannelNotInCopy` judges it.
    ///
    /// Why per frequency: afconvert's mono mix of a mid/side recording (left A + B, right A − B) is A, and the
    /// copy is then exactly the channels' mix, so every fit of the copy onto the channels — the plain path's
    /// levels, and the mixed audit's least-squares fit — passes, and B is gone (the review of Wave 7 lane S,
    /// S1). Over a whole window the channels' Gram matrix is the same as two independent voices', so nothing
    /// that measures the window as one signal can tell them apart (its X2). Per frequency they differ: where B
    /// sounds the channels are in opposite polarity and the mix holds nothing there.
    ///
    /// Why two links, the channels against their mix and the mix against the copy, and not the channels
    /// against the copy directly (which measured the same on every fixture, F1001 `gates/03-measure.txt`
    /// against `04-measure.txt`): the two losses need different bounds. Mixing two channels loses some sound
    /// legitimately — a pair of microphones apart is comb-filtered in the mix — so that link allows a quarter
    /// (`mostMissingShare`); a good encode loses almost nothing the mix holds, so that link allows a tenth
    /// (`mostCopyMissingShare`), and catches a copy that kept one channel, which the first link cannot see.
    /// And the refusal can say which happened.
    public struct ChannelPresence: Sendable, Equatable {
        /// How many channels the recording was read with.
        public var channels: Int
        /// Per window, per channel: the channel's energy in the measured band, and the part of it in bins the
        /// channels' mono mix does not hold.
        public var windows: [[Measure]]
        /// Per window: the mix's energy in the measured band, and the part of it in bins the copy does not hold.
        public var mix: [Measure]

        public struct Measure: Sendable, Equatable {
            public var energy: Double
            public var missing: Double

            public init(energy: Double, missing: Double) {
                self.energy = energy
                self.missing = missing
            }
        }

        public init(channels: Int, windows: [[Measure]], mix: [Measure]) {
            self.channels = channels
            self.windows = windows
            self.mix = mix
        }
    }

    /// Each frame of the presence measurement: 4,096 frames at 16 kHz, 256 ms, a bin every 3.9 Hz. Long, so
    /// a copy out of step with the recording by a few hundred frames (an encoder's priming, a reader's
    /// rounding) shares most of each frame with the recording; fine, so two voices a few hertz apart fall in
    /// different bins.
    public static let presenceFrameSeconds: TimeInterval = 0.256

    /// How many frames, half-overlapping, each bin's projection and energy are summed over before it is
    /// judged: four, about half a second. One frame alone cannot tell a channel's sound from another
    /// channel's that the mix also holds at that bin; summed over several, the other channel's sound,
    /// unrelated to this one, adds up incoherently and the channel's own coherently.
    public static let presenceGroupFrames = 4

    /// The frequencies measured: 80 Hz to 4 kHz, where speech has nearly all its energy.
    public static let presenceBand: ClosedRange<Double> = 80...4_000

    /// A bin holds the sound it is checked for where the projection onto it reaches this share of what is
    /// expected — `weight × energy`, the channel's weight in the mix, or 1 for the mix in the copy — 12 dB
    /// under. A channel heard alone gives exactly that; beside another channel's unrelated sound the
    /// projection varies about it; beside the same sound in phase it is larger. In opposite polarity, where
    /// the mix cancels, it is nothing. A mix of two microphones apart (a phone's stereo, an A/B pair) holds a
    /// voice comb-filtered, and its notches fall under this too; they are narrow, so they hold a small part
    /// of a voice's energy (`mostMissingShare`, which says how small).
    public static let presenceShare = 0.25

    /// The most of a channel's energy in a window that may lie in bins the channels' mono mix does not hold
    /// before the copy is not shown to hold that channel's sound and the original is kept: a quarter.
    /// Measured through the real encoder on speech from `Scripts/bench/clips` and on the lane's twelve-tone
    /// voices (F1001, `gates/04-measure.txt`, `10-measure-final.txt`). A mid/side recording whose side voice
    /// is as loud as the middle one reads 0.29 in its worst window when the two talk over each other
    /// throughout, 0.5 as tones; a side voice 3 dB down, 0.33. A copy is refused on one window, so that is
    /// enough. Kept: independent voices, one per channel, at most 0.011; one silent channel, identical
    /// channels, a panned mix and correlated music, 0.004 at most, and correlated music widened by 3 ms,
    /// 0.086; two microphones apart with a room's echo, at most 0.16 (two talkers a metre apart); with no
    /// echo at all, a phone's spacing (7 frames, 0.44 ms) 0.04 and a pair up to 2 ms apart 0.15; a Haas
    /// widening of 10 or 20 ms, 0.10 at most. What it refuses that holds both voices: an echo-free pair a
    /// metre apart (3 ms), 0.34 in one window, where the comb filter's notches fall on every other harmonic of
    /// a voice — the mono mix does lose that much of it there, and no room is echo-free. A side voice 6 dB
    /// under the middle one, talking over it throughout, reads 0.2 as tones and 0.09 as speech, and is not
    /// caught; one that talks alone cancels in its stretch, which this and the level checks refuse.
    public static let mostMissingShare = 0.25

    /// The most of the mix's energy in a window that may lie in bins the copy does not hold. A tenth.
    /// Measured (the same log): every good copy above reads 0.003 at most — the encode drops only what is
    /// quiet in the mix, which weighs as little as it holds; a copy of the left channel alone of two
    /// independent voices reads 0.12 to 0.29, of two independent tone voices 0.5.
    public static let mostCopyMissingShare = 0.1

    /// Whether a bin with `energy`, expected in what is checked at `weight`, onto which that projects
    /// `projection`, holds its sound (`presenceShare`). No energy is nothing to hold, and is held. Not a
    /// number is not held.
    public static func soundFound(projection: Double, energy: Double, weight: Double) -> Bool {
        guard projection.isFinite, energy.isFinite, weight.isFinite else { return false }
        guard energy > 0 else { return true }
        return projection >= presenceShare * weight * energy
    }

    /// Why a copy is not shown to hold a channel's sound (F1001).
    public enum ChannelPresenceFinding: Sendable, Equatable {
        /// More than `mostMissingShare` of the channel's sound in this window is not in the channels' mono
        /// mix: it cancels against the other channel.
        case missing(window: Int, channel: Int)
        /// More than `mostCopyMissingShare` of the mix's sound in this window is not in the copy.
        case copyMissing(window: Int)
        /// A channel sounds in this window but was not measured there, or a measure is not a number: not
        /// shown, so not deleted.
        case unmeasured(window: Int, channel: Int)
    }

    /// The first window and channel whose sound the copy is not shown to hold, or nil (F1001). In every window
    /// in which a channel sounds — `audibleShare` of its own level over the whole recording, from its own
    /// decode (`nativeChannelWindows`, per `MeetingStoragePlan.levelWindowSeconds`), and above
    /// `MeetingStoragePlan.silenceLevel` — the channel and the mix must have been measured, as finite numbers,
    /// with no more than `mostMissingShare` of the channel's measured energy missing from the mix, and no more
    /// than `mostCopyMissingShare` of the mix's missing from the copy. A window whose measured band holds none
    /// of a sounding channel's energy (sound only under 80 Hz or over 4 kHz) has nothing this can judge; the
    /// level checks still do. Nor does a window with no mix measured against the copy, past the copy's end,
    /// which the length check judges. The measure must have the recording's channel count.
    public static func firstChannelNotInCopy(_ presence: ChannelPresence,
                                             nativeChannelWindows: [[Double]]) -> ChannelPresenceFinding? {
        guard presence.channels == nativeChannelWindows.count, presence.channels > 0 else {
            return .unmeasured(window: 0, channel: 0)
        }
        func floor(_ level: Double) -> Double { Swift.max(MeetingStoragePlan.silenceLevel, level * audibleShare) }
        for (channel, levels) in nativeChannelWindows.enumerated() {
            if let window = levels.firstIndex(where: { !$0.isFinite }) { return .unmeasured(window: window, channel: channel) }
        }
        let floors = nativeChannelWindows.map { levels in
            floor(levels.isEmpty ? 0 : (levels.reduce(0) { $0 + $1 * $1 } / Double(levels.count)).squareRoot())
        }
        func valid(_ measure: ChannelPresence.Measure) -> Bool {
            measure.energy.isFinite && measure.missing.isFinite && measure.energy >= 0 && measure.missing >= 0
        }
        func tooMuchMissing(_ measure: ChannelPresence.Measure, _ share: Double) -> Bool {
            measure.energy > 0 && !(measure.missing <= measure.energy * share)
        }
        let windows = nativeChannelWindows.map(\.count).max() ?? 0
        for window in 0..<windows {
            var sounds = false
            for channel in 0..<presence.channels {
                let levels = nativeChannelWindows[channel]
                guard window < levels.count, levels[window] >= floors[channel] else { continue }
                sounds = true
                guard window < presence.windows.count, channel < presence.windows[window].count,
                      valid(presence.windows[window][channel]) else {
                    return .unmeasured(window: window, channel: channel)
                }
                if tooMuchMissing(presence.windows[window][channel], mostMissingShare) {
                    return .missing(window: window, channel: channel)
                }
            }
            guard sounds else { continue }
            guard window < presence.mix.count, valid(presence.mix[window]) else { return .unmeasured(window: window, channel: 0) }
            if tooMuchMissing(presence.mix[window], mostCopyMissingShare) { return .copyMissing(window: window) }
        }
        return nil
    }
}
