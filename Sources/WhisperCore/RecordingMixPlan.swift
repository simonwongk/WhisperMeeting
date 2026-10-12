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
        /// Every channel of every track is summed into one mono signal (`channels` of them in all),
        /// each placed at its own time, and that is what the engines, speaker analysis and Shrink get.
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

    /// What the mix does to the level of a voice that is alone on its track or channel: the gain
    /// `FloatTrackMixer` gives a capture's two tracks while their sum fits (F345). Shrink's check that
    /// every channel reached its copy allows for it.
    public static var gain: Double { Double(FloatTrackMixer.soloGain) }
}
