import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F188 item 4 — the inventory of persisted roots, written as a guard rather than as a document.
//
// The ticket asks for "a checked-in inventory of persisted roots". A document is the wrong artifact:
// this codebase spent 2026-09-17 finding prose that had outlived its code, twice within the hour of
// being written, and an inventory is prose whose whole job is to stay true as types change.
//
// What the inventory was FOR is the property that a newer build's value cannot make a root
// unreadable. So each root is round-tripped with an unfamiliar enum value in it, and asserted to
// survive.
//
// **What this does and does not catch, measured rather than claimed.** An earlier version of this
// paragraph said it "fails loudly when someone adds a throwing enum to a persisted type, which is
// the event the inventory existed to make visible". That is true of a REQUIRED field and false of
// an OPTIONAL one, and the asymmetry runs the wrong way:
//
//     new throwing enum, optional field       -> decodes; this guard stays green
//     new throwing enum, required field       -> throws; this guard fails loudly
//     new throwing enum, required + default   -> throws; the synthesized decoder ignores the
//                                                default and still demands the key
//
// Optional is how a persisted type normally gains a field — that is the whole point of F188's
// append-only rule — so the claim failed in exactly the case this exists to cover and held in the
// case that would have been caught anyway. The reason is narrow: every fixture below predates such
// a field, so the key is absent and `decodeIfPresent` returns nil without entering the enum's
// decoder. A key that IS present with an unmatched value throws, whether the fixture was written by
// hand or generated.
//
// So the gap is *unexercised*, not *unknown*, and the repair is a fixture derived from the type
// carrying every optional field with a deliberately unmatched value. That repair is
// `PersistedRootDerivedDecodeTests.swift` (F382): a fully populated fixture per root, checked
// complete by F544's `Mirror` walk, with each string and number leaf replaced in turn by an unknown
// value. The table above still describes THIS file; the derived one is what goes red on the first
// row. An explicit JSON `null` also returns nil without throwing, which is why that file never
// substitutes it.
//
// **And do not assert it with a round-trip.** A property with a declared default that is missing
// from `MeetingRecord`'s hand-written `CodingKeys` encodes to nothing and decodes back to its
// default, so the value returns correct having never been written:
//
//     struct Row: Codable { var id: Int; var schemaVersion: Int = 2
//                           enum CodingKeys: String, CodingKey { case id } }
//     encode -> {"id":1}          round-trip -> schemaVersion == 2
//
// That is F304's exact failure — a field persisted by nothing — surviving a test written to catch
// it. Distinct from the absent-key case above: there the property IS in `CodingKeys` and the JSON
// omits the key; here the property is not in `CodingKeys` at all, so the decoder never looks and
// the default fills in. Assert the encoded bytes (`JSONSerialization` on the output, or
// `MeetingRecordWireFormatTests`' `Mirror` check), never a decode of your own encode.
//
// whisper-37 hit this an hour after we agreed the rule, in a test whose own comment said "and it
// reaches disk".
//
// The four roots, all through `BackupJSONStore`, established by the F188 review:
//   [MeetingRecord] · [String] (vocabulary) · [ReplacementRule] · DictationLog
// This line is a note, not the authority: `everyPersistedRootIsCovered` in
// `PersistedRootDerivedDecodeTests.swift` scans Sources for `BackupJSONStore<…>` and fails when the
// set changes (F382).
//
// The two members the F188 review found throwing are both lenient now, and each has a test below:
// `MeetingTranscriptionEngine` (F250, stored as a raw string) and `DictationLogEntry.Outcome`
// (F251, an unknown case reads as `.failed` carrying its name).

private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
}

@Test("A meeting record with an unfamiliar status still decodes")
func meetingRecordSurvivesAnUnknownStatus() throws {
    // `MeetingStatus` is documented as lenient. This is the assertion that keeps it so.
    let record = try decode(MeetingRecord.self, from: #"""
    {"id":"A1000000-0000-4000-8000-000000000001","title":"From a newer build",
     "createdAt":"2026-09-17T10:00:00Z","duration":60,"recordingPath":"","status":"quantumSuperposed",
     "transcriptText":"","segments":[]}
    """#)
    #expect(record.title == "From a newer build")
}

@Test("A meeting record with an unfamiliar transcription engine still decodes")
func meetingRecordSurvivesAnUnknownEngine() throws {
    // F250's subject, and whisper-37 fixed it by storing the raw string. Asserted here because it
    // is the one member of this root that was NOT lenient, and a regression would be invisible
    // until a user's whole library stopped loading.
    let record = try decode(MeetingRecord.self, from: #"""
    {"id":"A1000000-0000-4000-8000-000000000002","title":"Engine from the future",
     "createdAt":"2026-09-17T10:00:00Z","duration":60,"recordingPath":"","status":"completed",
     "transcriptText":"","segments":[],"transcriptionEngine":"whisperFromTheFuture"}
    """#)
    #expect(record.title == "Engine from the future")
    // Unknown means unknown — not silently coerced to a real engine, which would make a
    // second-opinion run compare against the wrong one (F142).
    #expect(record.transcriptionEngine == nil)
}

@Test("A meeting record with an unfamiliar media-source kind still decodes")
func meetingRecordSurvivesAnUnknownMediaSource() throws {
    let record = try decode(MeetingRecord.self, from: #"""
    {"id":"A1000000-0000-4000-8000-000000000003","title":"Source from the future",
     "createdAt":"2026-09-17T10:00:00Z","duration":60,"recordingPath":"","status":"completed",
     "transcriptText":"","segments":[],
     "source":{"kind":"teleportedIn","pageURL":"https://example.com/a","host":"example.com",
                "fetchedAt":"2026-09-17T10:00:00Z","fieldFromTheFuture":1}}
    """#)
    #expect(record.title == "Source from the future")
}

@Test("A meeting record carrying fields this build has never heard of still decodes")
func meetingRecordSurvivesUnknownKeys() throws {
    // The other direction of the same guarantee: a newer build adding a field must not stop an
    // older one reading the library, or a downgrade wipes it — which is the 2026-08-14 shape.
    let record = try decode(MeetingRecord.self, from: #"""
    {"id":"A1000000-0000-4000-8000-000000000004","title":"Extra keys",
     "createdAt":"2026-09-17T10:00:00Z","duration":60,"recordingPath":"","status":"completed",
     "transcriptText":"","segments":[],"somethingAddedLater":{"nested":[1,2,3]},"anotherOne":true}
    """#)
    #expect(record.title == "Extra keys")
}

@Test("A replacement rule with unknown keys still decodes")
func replacementRuleSurvivesUnknownKeys() throws {
    let rule = try decode(ReplacementRule.self, from: #"""
    {"heard":"kestrelle","preferred":"Kestrel","addedLater":"ignored"}
    """#)
    #expect(rule.preferred == "Kestrel")
}

@Test("A transcript segment with unknown keys still decodes")
func transcriptSegmentSurvivesUnknownKeys() throws {
    // Nested inside `[MeetingRecord]`, so a throw here takes the whole library rather than one
    // segment — which is why the F188 review enumerated nested types and not just roots.
    let segment = try decode(TranscriptSegment.self, from: #"""
    {"speaker":null,"start":0,"end":1,"text":"hello","confidenceFromTheFuture":0.9}
    """#)
    #expect(segment.text == "hello")
}

@Test("A recording marker with unknown keys still decodes")
func recordingMarkerSurvivesUnknownKeys() throws {
    let marker = try decode(RecordingMarker.self, from: #"""
    {"id":"C1000000-0000-4000-8000-000000000001","offset":12.5,"label":"pricing",
     "colourAddedLater":"red"}
    """#)
    #expect(marker.offset == 12.5)
}

@Test("A dictation log with an unfamiliar outcome still decodes, as .failed carrying the case name (F251)")
func dictationLogSurvivesAnUnknownOutcome() throws {
    // Decoded as the ROOT, because the whole-log failure is the one that matters: one entry from a
    // newer build used to make the user's entire dictation history unreadable (F251, fixed).
    //
    // This replaced `dictationOutcomeGapIsRecorded`, which asserted the decode THREW and passed
    // vacuously (F382). Its fixture had `startedAt` and `durationSeconds`, which `DictationLogEntry`
    // does not have, lacked the required `date` and `text`, and spelled the outcome as a string
    // where the wire shape is a single-key object — so it threw `keyNotFound` on `date` whatever
    // the outcome decoder did. It was written the day after F251's fix (ff2f7c7), called F251
    // still open, and passed anyway. An assertion that the decode *succeeds* cannot be satisfied by
    // a malformed fixture, which is why this one asserts that direction.
    let log = try decode(DictationLog.self, from: #"""
    {"entries":[{"id":"B1000000-0000-4000-8000-000000000001","date":"2026-09-17T10:00:00Z",
     "text":"kept","outcome":{"teleported":{}}}],"limit":100}
    """#)
    let entry = try #require(log.entries.first)
    #expect(entry.text == "kept")
    #expect(entry.outcomeKind == "teleported")
    guard case .failed = entry.outcome else {
        Issue.record("an unknown outcome should read as .failed, got \(entry.outcome)")
        return
    }
}
