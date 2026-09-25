import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F471 — `MeetingRecord.requestedLanguage` is the language a meeting's transcription was asked to
// run in, kept apart from `languageCode`, which is what the engine returned. It is the only thing a
// per-segment re-run may pin on. Persisted-schema rules (AGENTS.md, F188): the field is optional and
// append-only, an index without it decodes, and a value this build does not know decodes leniently
// and survives a save — fixtures in both directions, as F250 wrote for the engine.

private func decodedRecord(_ json: String) throws -> MeetingRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
}

private func reencoded(_ record: MeetingRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(record), as: UTF8.self)
}

/// A code-switched meeting whose engine detected Mandarin as the majority, written by a build that
/// did not record the requested language.
private let olderRecord = #"""
{"id":"6F1A0000-0000-4000-8000-000000000002","title":"Planning",
 "createdAt":"2026-09-24T04:00:00Z","duration":1800,"recordingPath":"x/meeting.wav",
 "status":"completed","transcriptText":"我们的 deadline 是这个星期五。","languageCode":"zh",
 "segments":[],"markers":[],"tags":[],"pinned":false,"notes":""}
"""#

private func record(requestedLanguage: String) -> String {
    olderRecord.replacingOccurrences(
        of: #""notes":"""#,
        with: #""notes":"","requestedLanguage":"\#(requestedLanguage)""#
    )
}

@Test("An index written before the field existed decodes with no requested language, and no pin (F471)")
func anOlderIndexDecodesWithNoRequestedLanguage() throws {
    // The direction that protects every existing library: the key is absent, and absent is nil.
    // And nil is "nothing known about a pin", so the re-run detects — the stored "zh" is not read
    // as one, which is the defect this field exists to close.
    let record = try decodedRecord(olderRecord)
    #expect(record.requestedLanguage == nil)
    #expect(record.languageCode == "zh")
    #expect(WhisperLanguage(storedRequestedLanguage: record.requestedLanguage) == .automatic)
}

@Test("A requested language decodes, is written back, and is the pin the re-run reads (F471)")
func aRequestedLanguageRoundTrips() throws {
    for language in WhisperLanguage.allCases {
        let decoded = try decodedRecord(record(requestedLanguage: language.rawValue))
        #expect(decoded.requestedLanguage == language.rawValue)
        #expect(WhisperLanguage(storedRequestedLanguage: decoded.requestedLanguage) == language)
        // Reaching the wire is the half that matters: `MeetingStore` rewrites the whole index on
        // every change, so a value this build could read but not write would be erased by the next
        // edit to any meeting — F304's failure, which `everyStoredFieldIsEncoded` guards in general
        // and this pins for the one field.
        let json = try reencoded(decoded)
        #expect(json.contains(#""requestedLanguage":"\#(language.rawValue)""#))
        #expect(try decodedRecord(json).requestedLanguage == language.rawValue)
    }
}

@Test("A requested language this build cannot pin decodes, survives a save, and detects (F471)")
func anUnknownRequestedLanguageIsKeptAndDetects() throws {
    // The other direction: an index written by a newer build that offers a language this one does
    // not. The whole record decodes (a `String?` has no value it can fail on), the value is kept so
    // a downgrade is not destructive, and the re-run detects rather than pinning a guess.
    let decoded = try decodedRecord(record(requestedLanguage: "japanese"))
    #expect(decoded.title == "Planning", "the whole record must survive, not just the field")
    #expect(decoded.requestedLanguage == "japanese")
    #expect(WhisperLanguage(storedRequestedLanguage: decoded.requestedLanguage) == .automatic)
    let json = try reencoded(decoded)
    #expect(json.contains(#""requestedLanguage":"japanese""#))
    #expect(try decodedRecord(json).requestedLanguage == "japanese")
}

@Test("A key this build has never heard of is ignored, which is how the build before this one reads what this one writes (F471)")
func aKeyThisBuildDoesNotKnowIsIgnored() throws {
    // The "previously shipped build can read what this one writes" half, modelled from this side:
    // `Codable` with a hand-written `CodingKeys` skips a key it does not list, so the build before
    // F471 — which does not list `requestedLanguage` — reads this build's index and drops the field
    // on its next save, and nothing else. Stated here so the compatibility claim rests on an
    // assertion rather than on knowledge of `Codable`.
    let decoded = try decodedRecord(olderRecord.replacingOccurrences(
        of: #""notes":"""#,
        with: #""notes":"","aFieldFromAFutureBuild":{"nested":[1,2,3]}"#
    ))
    #expect(decoded.title == "Planning")
    #expect(decoded.requestedLanguage == nil)
}
