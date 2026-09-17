import Foundation

/// The user-entered metadata of a recording in progress: what they called it and where they marked
/// it (F258).
///
/// Distinct from `MeetingRecord`, which only exists once a recording has been stopped and indexed.
/// This is the part that used to live solely in `AppModel.pendingMarkers` and a text field, and was
/// therefore destroyed by any end the app did not control.
public struct RecordingSession: Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var title: String
    public var markers: [RecordingMarker]

    public init(id: UUID, startedAt: Date, title: String, markers: [RecordingMarker]) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.markers = markers
    }
}

/// Persists a `RecordingSession` beside the audio while the recording is live, so an interruption
/// loses the metadata no more than it loses the audio (F258).
///
/// **Why this exists.** The raw `.f32` tracks are written continuously, so audio survives ⌘Q, a
/// crash, a shutdown and a kernel panic — but the title and markers reached disk only in
/// `stopRecording`'s upsert. A meeting that ended any other way came back as
/// "Recovered Meeting <date>" with no markers, which for a long recording means re-scrubbing hours
/// of audio to find moments the user had already flagged.
///
/// Field evidence this is the interruption class that actually happens: a real 63-minute meeting in
/// the library had no `meeting.wav` and no `source-tracks.json` — `stop()` never ran — with 62.3
/// minutes of wall clock against 63.0 minutes of captured audio, i.e. no sleep gap. The capture ran
/// to the end and the process died.
///
/// **The one hard rule.** Reading is failure-tolerant and never throws. `performStartupRecovery`'s
/// job is to rebuild the *audio*; a missing, truncated or unreadable metadata file must never be
/// able to stop that. Losing markers is survivable, losing the meeting is not — so `read` answers
/// nil for anything it cannot parse.
public enum RecordingSessionSidecar {
    /// Deliberately not one of the names `InterruptedRecordingRecovery` keys on. A file in a
    /// recording folder is load-bearing: `finalizedRecording(in:)` decides "this recording finished"
    /// from `meeting.wav` / `meeting-recovered.wav` / `recording.<ext>`, and `removeIfEmpty` decides
    /// whether a folder is discardable from whether it holds anything at all.
    public static let filename = "session.json"

    /// Writes the session atomically, replacing any previous copy.
    ///
    /// Atomic because this is rewritten on every marker drop while a capture is streaming audio to
    /// the same folder: a torn write would be read back as corrupt, and while `read` tolerates that,
    /// it would silently cost the user the markers this file exists to keep.
    public static func write(_ session: RecordingSession, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    /// The session recorded for `directory`, or nil when there is none that can be read.
    ///
    /// Never throws — see the type's doc comment. Absent, truncated, and written-by-a-future-build
    /// are all "no metadata", which is exactly what the caller does with them anyway.
    public static func read(in directory: URL) -> RecordingSession? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSession.self, from: data)
    }
}
