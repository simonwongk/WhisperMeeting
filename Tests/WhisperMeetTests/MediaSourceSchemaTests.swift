import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F183 — adding fields to MeetingRecord is the one genuinely dangerous change in this feature. Swift's
// synthesized init(from:) does not consult a property's default value, so a NON-optional new field makes
// every pre-existing meeting fail to decode — and the failure compounds: the library loads empty and the
// next persistMeetings() overwrites both meetings.json and meetings.backup.json. These lock the
// optionality in with the actual on-disk shape.

@MainActor
@Test("A meetings index written before the link-import fields still loads every meeting (F183)")
func legacyIndexStillDecodes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaSourceSchemaTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A pre-F183 record: no "source", no "referenceSegments" keys at all. Dates are ISO8601 because
    // that is the strategy BackupJSONStore actually persists with.
    let legacy = """
    [{"id":"\(UUID().uuidString)","title":"Old meeting","createdAt":"2026-04-22T00:00:00Z",\
    "duration":61.5,"recordingPath":"Recordings/x/recording.wav","status":"completed",\
    "transcriptText":"hello","segments":[]}]
    """
    try Data(legacy.utf8).write(to: root.appendingPathComponent("meetings.json"))

    let store = MeetingStore(rootDirectory: root)
    #expect(store.meetings.count == 1)                    // the library is NOT empty
    #expect(store.meetings.first?.title == "Old meeting") // and the record survived intact
    #expect(store.meetings.first?.source == nil)
    #expect(store.meetings.first?.referenceSegments == nil)
}

@Test("The new link-import fields round-trip through the index encoding (F183)")
func newFieldsRoundTrip() throws {
    let source = MediaSource(
        kind: MediaSource.youTubeKind, pageURL: "https://youtu.be/abc", host: "youtu.be",
        videoID: "abc", uploader: "Chan", uploadDate: nil, fetchedAt: Date(timeIntervalSince1970: 10)
    )
    let record = MeetingRecord(
        title: "Linked", status: .completed,
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hi")],
        source: source,
        referenceSegments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "caption")]
    )
    let data = try JSONEncoder().encode([record])
    let decoded = try JSONDecoder().decode([MeetingRecord].self, from: data)
    #expect(decoded.first?.source == source)
    #expect(decoded.first?.source?.isYouTube == true)
    #expect(decoded.first?.referenceSegments?.first?.text == "caption")
}
