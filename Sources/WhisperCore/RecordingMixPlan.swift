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
        /// The alternate group it shares with other audio tracks — a movie's languages, of which a
        /// player plays one — or nil when it plays alongside the others.
        public var alternateGroup: Int?

        public init(channels: Int, alternateGroup: Int? = nil) {
            self.channels = channels
            self.alternateGroup = alternateGroup
        }
    }

    public enum Decision: Sendable, Equatable {
        /// One track of one or two channels: handed on as it is. The engines' own decodes mix two
        /// channels (ffmpeg's `-ac 1`; afconvert's `--mix`, F796), and Shrink's encode does too.
        case asItIs
        /// Every channel of every track is summed into one mono signal (`channels` of them in all),
        /// each placed at its own time, and that is what the engines, speaker analysis and Shrink get.
        case mixEveryChannel(channels: Int)
        /// Several tracks that should not be summed, or cannot be read: see `Refusal`.
        case unsupported(Refusal)
    }

    public enum Refusal: Sendable, Equatable {
        /// Audio tracks that are alternatives of one another (an alternate group). Summing two
        /// languages makes neither intelligible, so they are not mixed: the engines keep decoding the
        /// default one, as before, and Shrink refuses rather than delete the others.
        case alternateTracks(count: Int)
        /// A track whose channels could not be read.
        case unreadableTrack
    }

    public static func decision(for tracks: [Track]) -> Decision {
        guard !tracks.isEmpty else { return .asItIs }
        if tracks.contains(where: { $0.channels < 1 }) { return .unsupported(.unreadableTrack) }
        var groupSizes: [Int: Int] = [:]
        for group in tracks.compactMap(\.alternateGroup) { groupSizes[group, default: 0] += 1 }
        if groupSizes.values.contains(where: { $0 > 1 }) { return .unsupported(.alternateTracks(count: tracks.count)) }
        if tracks.count == 1, tracks[0].channels <= 2 { return .asItIs }
        return .mixEveryChannel(channels: tracks.reduce(0) { $0 + $1.channels })
    }

    /// What the mix does to the level of a voice that is alone on its track or channel: the gain
    /// `FloatTrackMixer` gives a capture's two tracks while their sum fits (F345). Shrink's check that
    /// every channel reached its copy allows for it.
    public static var gain: Double { Double(FloatTrackMixer.soloGain) }
}
