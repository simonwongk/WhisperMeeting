import Foundation

/// Re-running recovery on a folder the library has already indexed (F267).
///
/// Recovery is one-shot without this. `orphanedRecordings()` excludes any folder whose UUID belongs
/// to a meeting — deliberately, so a "recovery" cannot overwrite a saved title or transcript with a
/// blank stub (F148 #1) — so the moment a partial or wrong rebuild is indexed, the folder is
/// invisible to the recovery path forever, with the intact `.f32` tracks sitting beside it.
///
/// That property is load-bearing in two tickets that are already closed. F256's floor throws rather
/// than index a duration-0 meeting *because* such a meeting would be final; F279's severity
/// argument rests on a stranded recording being unrecoverable. Both were true by side effect rather
/// than by anyone's decision, which is why this exists at medium severity.
///
/// This type is the policy only: what may be rebuilt, and what a rebuild must not destroy. It never
/// touches the index — `AppModel` decides what a successful rebuild changes on the meeting, and
/// F148 #1 constrains that to the audio's own facts.
public enum SourceRebuild {
    private static let rebuiltName = "meeting-recovered.wav"
    private static let finalizedName = "meeting.wav"

    /// What a rebuild of one folder would do, for the user to review before it happens.
    public struct Offer: Sendable, Equatable {
        public let directory: URL
        /// What the raw tracks promise, from their size. The rebuild can come out shorter — that is
        /// F256's truncation — so this is an upper bound, not a prediction.
        public let expectedDurationSeconds: TimeInterval
        /// What the library currently believes, so the confirmation can state both.
        public let currentDurationSeconds: TimeInterval
        /// Whether an existing rebuild would be moved aside. False when the audio file is gone,
        /// which is the case with the most to gain and nothing to preserve.
        public let wouldSupersedeRecording: Bool
    }

    /// Whether this folder may be rebuilt again, and what that would involve. A pure read: it
    /// writes nothing and creates nothing.
    ///
    /// Two conditions, and the second is a refusal rather than a filter.
    ///
    /// **A folder holding `meeting.wav` is never offered.** That file is written only by
    /// `AudioCaptureEngine.stop()`, so its presence means a capture finished normally. Rebuilding
    /// over it and repointing the index at `meeting-recovered.wav` is precisely the harm F255
    /// exists to prevent — the complete recording left on disk with nothing referring to it. A user
    /// who believes their `meeting.wav` is bad has the documented manual procedure; the app will
    /// not do it for them on a guess.
    ///
    /// The tracks must also declare more than zero frames, or there is nothing to rebuild from.
    public static func offer(
        in directory: URL,
        currentDuration: TimeInterval,
        sampleRate: Double = 48_000
    ) -> Offer? {
        offer(
            in: directory,
            currentDuration: currentDuration,
            sampleRate: sampleRate,
            sizeOf: InterruptedRecordingRecovery.fileSizeLookup
        )
    }

    /// The seam pair for the two entry points above. Internal, because `SizeLookup` and
    /// `TrackOpener` are the injection points F256 and F280 added for testability and have no
    /// business in this module's public surface — `AppModel` only ever wants the real ones.
    static func offer(
        in directory: URL,
        currentDuration: TimeInterval,
        sampleRate: Double,
        sizeOf sizeLookup: InterruptedRecordingRecovery.SizeLookup
    ) -> Offer? {
        guard !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(finalizedName).path
        ) else { return nil }

        // `try?` here and not below: this is the *availability* question, and a track that cannot
        // be stat'd is one this offer cannot describe honestly, so not offering is the right
        // answer. The rebuild itself uses the throwing lookup, where F280 applies.
        let frames = InterruptedRecordingRecovery.sourceTrackFrames(
            in: directory,
            sizeOf: { (try? sizeLookup($0)) ?? nil }
        )
        guard frames > 0 else { return nil }

        return Offer(
            directory: directory,
            expectedDurationSeconds: Double(frames) / sampleRate,
            currentDurationSeconds: currentDuration,
            wouldSupersedeRecording: FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(rebuiltName).path
            )
        )
    }

    /// Rebuilds, keeping every recording the folder already holds.
    ///
    /// "Never delete audio" has to cover overwriting. The rebuild writes a fixed filename, so a
    /// second run would destroy the first — that is deleting audio, and the fixed name is what
    /// makes it invisible. The existing file moves to `meeting-recovered-superseded-<n>.wav`,
    /// lowest unused `n` from 1, and the new rebuild takes the original name so the meeting's
    /// `recordingPath` stays valid.
    ///
    /// Disk grows by roughly one meeting's audio per rebuild. That is stated in the confirmation
    /// rather than solved: a silent cap that discarded the user's audio would be the same defect in
    /// a smaller font.
    ///
    /// On failure the previous recording is put back. Losing the old audio to a failed attempt at
    /// better audio is worse than the truncation being fixed.
    @discardableResult
    public static func rebuild(
        _ offer: Offer,
        sampleRate: Double = 48_000
    ) throws -> RecoveredRecording? {
        try rebuild(
            offer,
            sampleRate: sampleRate,
            openTrack: InterruptedRecordingRecovery.fileTrackOpener
        )
    }

    @discardableResult
    static func rebuild(
        _ offer: Offer,
        sampleRate: Double = 48_000,
        openTrack: InterruptedRecordingRecovery.TrackOpener
    ) throws -> RecoveredRecording? {
        let fileManager = FileManager.default
        let existing = offer.directory.appendingPathComponent(rebuiltName)
        var movedAside: URL?
        if fileManager.fileExists(atPath: existing.path) {
            let destination = nextSupersededURL(in: offer.directory)
            try fileManager.moveItem(at: existing, to: destination)
            movedAside = destination
        }
        do {
            return try InterruptedRecordingRecovery.rebuildFromSourceTracks(
                in: offer.directory,
                sampleRate: sampleRate,
                openTrack: openTrack
            )
        } catch {
            // `rebuildFromSourceTracks` removes its own header-less stub on the way out (F256), so
            // the original name is free to move back into.
            if let movedAside {
                try? fileManager.moveItem(at: movedAside, to: existing)
            }
            throw error
        }
    }

    /// The lowest unused `meeting-recovered-superseded-<n>.wav`. Counting rather than timestamping
    /// so a folder rebuilt twice in the same second still keeps both.
    private static func nextSupersededURL(in directory: URL) -> URL {
        var index = 1
        while true {
            let candidate = directory
                .appendingPathComponent("meeting-recovered-superseded-\(index).wav")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
