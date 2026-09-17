import Foundation

/// `source-tracks.json` — the durable description of the raw `.f32` tracks beside a recording.
///
/// Moved out of `AudioCaptureEngine` by F282, where it was `private` and therefore untestable. That
/// is how it came to describe something it no longer matched: F275 began padding gaps into the
/// tracks and this file went on saying nothing about it, so a patched recording was
/// byte-indistinguishable from one that was never interrupted. A manifest nothing can test is a
/// claim nobody checks.
public struct SourceTrackManifest: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public let file: String
        public let format: String
        public let sampleRate: Double
        public let channels: Int
        public let frameCount: Int64
        public let startOffsetSeconds: Double
    }

    /// A span of the recording that is inserted silence rather than captured audio (F282).
    ///
    /// **Positional, and that is the point.** An alignment value saying "padded" tells a consumer
    /// that something was inserted; it does not tell them *where*, so they still cannot skip those
    /// spans and would count inserted silence as recorded non-speech — which matters most to the
    /// forced aligner and to anything deriving speaker statistics. The ticket was filed as though
    /// the label were the fix; the list is the fix and the label is the label.
    public struct PaddedGap: Codable, Equatable, Sendable {
        /// Where the gap begins, in the recording's own timeline.
        public let startSeconds: Double
        public let durationSeconds: Double

        public init(startSeconds: Double, durationSeconds: Double) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
    }

    /// An uninterrupted capture: sample offset is elapsed time, with nothing inserted.
    public static let capturedAlignment = "captured-timeline"

    /// A capture that lost and regained its stream, with the gap padded (F275).
    ///
    /// Deliberately the same string as `CaptureRestartPolicy.paddedAlignment` and asserted equal by
    /// a test: two literals in two files describing one state is how they begin to disagree. The
    /// policy owns the vocabulary because it owns the decision.
    public static let paddedAlignment = CaptureRestartPolicy.paddedAlignment

    /// How this recording's timeline relates to wall clock. A **label**, not a log: it names the
    /// single most significant thing that happened to the timeline, and anything needing a history
    /// of transformations should add its own field rather than overload this one.
    public let recoveryAlignment: String

    /// Inserted-silence spans, oldest first. Empty for an ordinary capture.
    public let paddedGaps: [PaddedGap]

    /// Set only when a rebuild stopped early (F256), so the folder explains its own state without
    /// the index. Nil on a clean capture, which has no truncation concept.
    public let truncatedAtSeconds: TimeInterval?

    public let systemAudio: Track
    public let microphoneAudio: Track

    /// A zero-aligned rebuild, with no presentation timestamps to offset from.
    public static let rebuiltAlignment = "zero-aligned-after-interruption"

    /// A rebuild of a capture that had already padded a gap — both facts are true of the file, and
    /// the rebuild's own alignment is the less specific of the two (F282). It says how the tracks
    /// were joined; the gaps say which spans are not audio at all.
    public static let rebuiltPaddedAlignment = "zero-aligned-after-interruption-with-padding"

    public init(
        recoveryAlignment: String = SourceTrackManifest.capturedAlignment,
        paddedGaps: [PaddedGap] = [],
        truncatedAtSeconds: TimeInterval? = nil,
        systemAudio: Track,
        microphoneAudio: Track
    ) {
        self.recoveryAlignment = recoveryAlignment
        self.paddedGaps = paddedGaps
        self.truncatedAtSeconds = truncatedAtSeconds
        self.systemAudio = systemAudio
        self.microphoneAudio = microphoneAudio
    }

    /// The alignment for a rebuild, which depends on whether the capture had padded anything.
    ///
    /// A lookup into the closed set above rather than a string built from parts. Every reader
    /// compares this field by equality, so an assembled value is one nobody can match — and the
    /// composition does not survive a second dimension: rebuild history belongs in its own field,
    /// not in a longer name.
    public static func alignment(
        forRebuildWith base: String,
        paddedGaps: [PaddedGap]
    ) -> String {
        guard !paddedGaps.isEmpty else { return base }
        switch base {
        case rebuiltAlignment: return rebuiltPaddedAlignment
        // An unrecognised base means a caller introduced an alignment without adding its padded
        // counterpart here. Returning the base unchanged loses the padding from the LABEL, which is
        // the lesser harm: `paddedGaps` still carries the positions, and those are what a consumer
        // acts on. Better an under-specific label than an invented one.
        default: return base
        }
    }

    /// Decoded leniently for the two fields F282 added, so every manifest already on disk still
    /// reads — the same rule F188 set and F250 applied to the meeting index.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemAudio = try container.decode(Track.self, forKey: .systemAudio)
        microphoneAudio = try container.decode(Track.self, forKey: .microphoneAudio)
        recoveryAlignment = try container.decodeIfPresent(String.self, forKey: .recoveryAlignment)
            ?? SourceTrackManifest.capturedAlignment
        paddedGaps = try container.decodeIfPresent([PaddedGap].self, forKey: .paddedGaps) ?? []
        truncatedAtSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .truncatedAtSeconds
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recoveryAlignment, forKey: .recoveryAlignment)
        try container.encode(systemAudio, forKey: .systemAudio)
        try container.encode(microphoneAudio, forKey: .microphoneAudio)
        // Omitted when empty rather than written as `[]`. `source-tracks.json` is read by
        // `AppModel.sourceTracks`, which takes only `file` and `frameCount`, so an additive field is
        // safe either way — but a field present on every recording stops being a signal, and the
        // absence of this one is the ordinary case.
        if !paddedGaps.isEmpty { try container.encode(paddedGaps, forKey: .paddedGaps) }
        try container.encodeIfPresent(truncatedAtSeconds, forKey: .truncatedAtSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryAlignment, paddedGaps, truncatedAtSeconds, systemAudio, microphoneAudio
    }

    /// Builds a manifest for a rebuilt recording, where there are no presentation timestamps and
    /// the tracks are zero-aligned by construction (F282).
    ///
    /// Unified with the capture path's manifest rather than kept as a second type. Two types
    /// describing the same two files in two shapes — the recovered one lacked
    /// `startOffsetSeconds` entirely — is the defect underneath this ticket: a field added to one
    /// was simply absent from the other, and `AppModel.sourceTracks` reads whichever it finds.
    public static func rebuilt(
        sampleRate: Double,
        systemFile: String,
        systemFrameCount: Int64,
        microphoneFile: String,
        microphoneFrameCount: Int64,
        paddedGaps: [PaddedGap],
        truncatedAtSeconds: TimeInterval?,
        alignment: String
    ) -> SourceTrackManifest {
        func track(_ file: String, _ frames: Int64) -> Track {
            Track(
                file: file,
                format: "float32-little-endian",
                sampleRate: sampleRate,
                channels: 1,
                frameCount: frames,
                // Zero by construction, and true rather than a filler: a rebuild has no
                // presentation timestamps to offset from, which is what "zero-aligned" means.
                startOffsetSeconds: 0
            )
        }
        return SourceTrackManifest(
            recoveryAlignment: alignment,
            paddedGaps: paddedGaps,
            truncatedAtSeconds: truncatedAtSeconds,
            systemAudio: track(systemFile, systemFrameCount),
            microphoneAudio: track(microphoneFile, microphoneFrameCount)
        )
    }

    /// Writes the manifest for a finished capture.
    public static func write(
        system: FloatTrack,
        microphone: FloatTrack,
        sampleRate: Double,
        paddedGaps: [PaddedGap] = [],
        to outputURL: URL
    ) throws {
        let starts = [system.firstPresentationTime, microphone.firstPresentationTime]
            .compactMap { $0 }
        guard let earliestStart = starts.min() else {
            throw FloatTrackMixError.noAudioCaptured
        }
        let manifest = Self(
            recoveryAlignment: paddedGaps.isEmpty ? capturedAlignment : paddedAlignment,
            paddedGaps: paddedGaps,
            systemAudio: track(system, sampleRate: sampleRate, earliestStart: earliestStart),
            microphoneAudio: track(microphone, sampleRate: sampleRate, earliestStart: earliestStart)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputURL, options: .atomic)
    }

    private static func track(
        _ track: FloatTrack,
        sampleRate: Double,
        earliestStart: Double
    ) -> Track {
        Track(
            file: track.url.lastPathComponent,
            format: "float32-little-endian",
            sampleRate: sampleRate,
            channels: 1,
            frameCount: track.frameCount,
            startOffsetSeconds: max(
                0,
                (track.firstPresentationTime ?? earliestStart) - earliestStart
            )
        )
    }
}
