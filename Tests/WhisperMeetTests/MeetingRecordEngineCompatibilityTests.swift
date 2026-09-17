import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F250 — `MeetingRecord.transcriptionEngine` was a raw-value enum with no lenient decode, so an
// index written by a build with an engine this one lacks failed with `DecodingError.dataCorrupted`.
// The persisted root is a single `[MeetingRecord]` array, so that one value failed the decode of
// **every** meeting: the whole library, unreadable.
//
// **This made adding any transcription engine a one-way door.** Once a meeting was saved with a new
// engine, no earlier build could open the library at all. F240 hit it while considering a
// whisper.cpp engine and recorded it as a blocker, which is how a compatibility gap became a
// roadmap constraint.
//
// **Why enum-level leniency could not fix it, and this could.** `Decodable` cannot yield `nil` from
// a type's own initialiser, and `decodeIfPresent` returns nil only for an absent or null key, never
// for a value that throws. So leniency at the enum would have to invent a case — and decoding an
// unrecognised engine as `.whisperLarge` would claim a meeting was transcribed by a model that never
// touched it. This field is a provenance record; a wrong answer is worse than no answer. Persisting
// the raw string moves the decision out of `Decodable` entirely: the string always round-trips, and
// the typed accessor answers nil for what this build does not know, which is the truth.

private func decodedRecord(_ json: String) throws -> MeetingRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
}

private let minimalRecord = #"""
{"id":"6F1A0000-0000-4000-8000-000000000001","title":"Budget review",
 "createdAt":"2026-09-17T04:00:00Z","duration":1800,"recordingPath":"x/meeting.wav",
 "status":"completed","transcriptText":"hello","segments":[],"markers":[],"tags":[],
 "pinned":false,"notes":""}
"""#

@Test("A meeting transcribed by an unknown engine still decodes (F250)")
func unknownEngineDecodesRatherThanFailing() throws {
    let json = minimalRecord.replacingOccurrences(
        of: #""notes":"""#,
        with: #""notes":"","transcriptionEngine":"whisper-cpp-large-v3""#
    )
    let record = try decodedRecord(json)

    #expect(record.title == "Budget review", "the whole record must survive, not just the engine")
    // Nil, not a guess. This build genuinely does not know what produced the transcript, and saying
    // `.whisperLarge` would be a claim about a model that never ran.
    #expect(record.transcriptionEngine == nil)
    // But the fact is not lost.
    #expect(record.transcriptionEngineRawValue == "whisper-cpp-large-v3")
}

@Test("An unknown engine survives a save, so a downgrade is not destructive (F250)")
func unknownEngineRoundTrips() throws {
    // The half that matters most. Decoding without throwing is not enough: `MeetingStore` persists
    // the entire index on every change, so an engine it could read but not write would be erased by
    // the next edit to any meeting — and the newer build would then have lost the provenance for
    // good. This is F266's amplifier in a different file.
    let json = minimalRecord.replacingOccurrences(
        of: #""notes":"""#,
        with: #""notes":"","transcriptionEngine":"whisper-cpp-large-v3""#
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    let once = try decodedRecord(json)
    let reencoded = try #require(String(data: encoder.encode(once), encoding: .utf8))
    #expect(reencoded.contains(#""transcriptionEngine":"whisper-cpp-large-v3""#))

    let twice = try decodedRecord(reencoded)
    #expect(twice.transcriptionEngineRawValue == "whisper-cpp-large-v3")
}

@Test("Known engines still map to their cases, on the wire and in the accessor (F250)")
func knownEnginesStillMap() throws {
    for (raw, expected) in [
        ("large", MeetingTranscriptionEngine.whisperLarge),
        ("turbo", .whisperTurbo),
        ("qwen3-asr-1.7b-8bit", .qwenBalanced),
    ] {
        let json = minimalRecord.replacingOccurrences(
            of: #""notes":"""#,
            with: #""notes":"","transcriptionEngine":"\#(raw)""#
        )
        let record = try decodedRecord(json)
        #expect(record.transcriptionEngine == expected)
        #expect(record.transcriptionEngineRawValue == raw)
    }
}

@Test("A record with no engine at all still decodes, and reports none (F250)")
func absentEngineIsStillNil() throws {
    let record = try decodedRecord(minimalRecord)
    #expect(record.transcriptionEngine == nil)
    #expect(record.transcriptionEngineRawValue == nil)
}

@Test("Setting the engine through the typed API writes the raw value (F250)")
func typedSetterWritesTheRawValue() throws {
    var record = try decodedRecord(minimalRecord)
    record.transcriptionEngine = .qwenBalanced
    #expect(record.transcriptionEngineRawValue == "qwen3-asr-1.7b-8bit")
    record.transcriptionEngine = nil
    #expect(record.transcriptionEngineRawValue == nil)
}

@Test("Every persisted field of a meeting still reaches the wire (F250)")
func theWireKeySetIsPinned() throws {
    // F250 replaces `MeetingRecord`'s synthesized `CodingKeys` with a hand-written one, so that the
    // raw engine string can be stored under a differently-named property while keeping the on-disk
    // key. Hand-writing `CodingKeys` on a 24-field persisted type is the kind of change that
    // silently drops a field — and a dropped field here means every meeting loses it on the next
    // save, with nothing failing. So the key set is pinned rather than trusted.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let record = MeetingRecord(
        id: UUID(),
        title: "t",
        createdAt: Date(),
        duration: 1,
        recordingPath: "p",
        status: .completed,
        transcriptText: "x",
        languageCode: "en",
        confidence: 0.5,
        segments: [],
        errorMessage: "e",
        transcriptNormalized: true,
        markers: [],
        pinned: true,
        notes: "notes",
        tags: ["tag"],
        alignmentWarning: "a",
        recoveryWarning: "r",
        languageWarning: "l",
        transcriptionEngine: .whisperLarge
    )
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
    )
    let expected: Set<String> = [
        "id", "title", "createdAt", "duration", "recordingPath", "status", "transcriptText",
        "languageCode", "confidence", "segments", "errorMessage",
        "transcriptNormalized", "markers", "pinned", "notes", "tags", "alignmentWarning",
        "recoveryWarning", "languageWarning", "transcriptionEngine",
    ]
    // 20 keys for 24 fields: `summary`, `healthReport`, `source` and `referenceSegments` are nil.
    #expect(expected.count == 20)
    // `summary`, `healthReport`, `source` and `referenceSegments` are left nil above, and a nil
    // optional is omitted rather than written as null — so they are absent by design, not by
    // omission from CodingKeys. Every field that CAN be non-nil is set, so the set below is the
    // full on-disk vocabulary minus those four.
    #expect(Set(object.keys) == expected,
            "a persisted field changed its on-disk name or stopped being written")
}
