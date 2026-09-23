import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F304 — `MeetingRecord` has a hand-written `CodingKeys` (F250 added it to remap
// `transcriptionEngineRawValue`), and a hand-written one means Swift encodes **only** the listed
// keys. Two fields were not listed, so they were in-memory only:
//
//   - `recoverySource`, which is the entirety of F273's fix. That ticket exists because provenance
//     lived in a field another path cleared; the fix moved it into a field nothing persisted. The
//     provenance survived transcription and did not survive a reload, which is the same
//     user-visible outcome through a different door.
//   - `staleTranscriptWarning`, F267's notice that a rebuilt recording's old transcript is stale.
//
// Two tickets forgot the same step, so the guard here is structural rather than two more
// assertions: every STORED property must appear in the wire format. `Mirror` sees stored properties
// and not computed ones, which is exactly the distinction that matters — `transcriptionEngine` is
// computed over `transcriptionEngineRawValue` and correctly absent.

/// Every field populated, because `JSONEncoder` omits a nil optional and a nil field would look
/// identical to a missing key. Anything added to `MeetingRecord` has to be added here too, and the
/// test below is what says so.
///
/// It said so within the hour. F305 added `recoveryInterruption` and this fixture did not set it;
/// the test named the field — *"these stored fields never reach disk: recoveryInterruption"* — while
/// `theWireKeySetIsPinned`, whose fixture also did not set it, passed. That is the whole difference
/// between deriving the list and restating it, demonstrated on a field added after both were
/// written.
private func fullyPopulatedRecord() -> MeetingRecord {
    MeetingRecord(
        id: UUID(),
        title: "Quarterly review",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 1234.5,
        recordingPath: "Recordings/x/meeting.wav",
        status: .completed,
        transcriptText: "hello",
        languageCode: "en",
        confidence: 0.92,
        segments: [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 1, text: "hello")],
        errorMessage: "an error",
        summary: MeetingSummary(
            summary: "s",
            keyPoints: ["k"],
            actionItems: [ActionItem(text: "a", done: false)]
        ),
        transcriptNormalized: true,
        markers: [RecordingMarker(offset: 5, label: "here")],
        pinned: true,
        notes: "notes",
        tags: ["tag"],
        healthReport: RecordingHealthReport(
            warnings: [.microphoneClipping],
            worstStatus: .caution,
            microphoneStaleSeconds: 0,
            systemAudioStaleSeconds: 0,
            systemAudioEverDetected: true
        ),
        alignmentWarning: "alignment",
        recoveryWarning: "recovery",
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
        staleTranscriptWarning: "stale",
        recoveryInterruption: RecoveryInterruption.systemSleep.rawValue,
        languageWarning: "language",
        repeatsRemoved: 15,
        transcriptionEngine: .qwenBalanced,
        source: MediaSource(
            kind: MediaSource.webKind,
            pageURL: "https://example.com/a",
            host: "example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        referenceSegments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello")]
    )
}

@Test("Every stored field of a MeetingRecord reaches the wire format (F304)")
func everyStoredFieldIsEncoded() throws {
    // The guard that makes the class impossible. A field absent from `CodingKeys` is dropped on the
    // next save with no error anywhere — the index still parses, the app still runs, and the fact is
    // simply gone.
    let record = fullyPopulatedRecord()
    let data = try JSONEncoder().encode(record)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let encodedKeys = Set(object.keys)

    // `Mirror` reports stored properties only, which is the right set: a computed property has
    // nothing to persist. `transcriptionEngine` is computed over the raw value and must NOT appear.
    let stored = Mirror(reflecting: record).children.compactMap(\.label)
    #expect(!stored.isEmpty, "Mirror found no properties, so this test would pass vacuously")
    #expect(!stored.contains("transcriptionEngine"), "a computed property should not be reflected")

    // The one documented remap (F250): the property is `transcriptionEngineRawValue`, the key is
    // `transcriptionEngine`, so the property name is not the key name for this one field.
    let remapped = ["transcriptionEngineRawValue": "transcriptionEngine"]

    var missing: [String] = []
    for property in stored {
        let key = remapped[property] ?? property
        if !encodedKeys.contains(key) { missing.append(property) }
    }
    #expect(
        missing.isEmpty,
        "these stored fields never reach disk, so they are lost on the next save: \(missing.sorted().joined(separator: ", "))"
    )
}

@Test("A record's recovery provenance and stale notice survive a save and reload (F304, F273, F267)")
func provenanceSurvivesARoundTrip() throws {
    // The instance, stated separately from the class above, because this is the one with a user
    // consequence: F273's whole subject is that this fact must outlive the things that happen to a
    // meeting, and a reload is the most ordinary of them.
    let record = fullyPopulatedRecord()
    let restored = try JSONDecoder().decode(
        MeetingRecord.self, from: try JSONEncoder().encode(record)
    )

    #expect(restored.recoverySource == RecoveredRecording.Source.rebuiltSourceTracks.rawValue)
    #expect(restored.staleTranscriptWarning == "stale")
    let caveats = MeetingStore.recoveryCaveats(for: restored)
    #expect(caveats.contains { $0.contains("rebuilt from its raw microphone") })
    #expect(caveats.contains("stale"))
}

@Test("An index written before these fields existed still decodes (F304)")
func olderIndexStillDecodes() throws {
    // The other half of the leniency rule (F250/F187): adding keys must not make an older index
    // unreadable. An absent key is nil, not a failure.
    let json = """
    {"id":"\(UUID().uuidString)","title":"old","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[]}
    """
    let restored = try JSONDecoder().decode(
        MeetingRecord.self, from: Data(json.utf8)
    )
    #expect(restored.recoverySource == nil)
    #expect(restored.staleTranscriptWarning == nil)
    #expect(MeetingStore.recoveryCaveats(for: restored).isEmpty)
}
