import Foundation
import Testing
@testable import WhisperCore

// F1016 — the dictation history marks a dictation the recognizer cut short (F762's and F1015's
// `truncated`), the user's decision of 2026-10-16. `dictation-log.json` is a wire format every build
// a user might launch shares, so per the persisted-schema rules (F188) the fixtures run in both
// directions: an entry written before F1016 decodes here unmarked, and the build before F1016 reads
// an entry this one writes. `PersistedWireFormatTests` derives the stored fields and sees it too.

/// `DictationLogEntry`'s decoder as it shipped before F1016 (at `6d2ea11`), copied key for key: a
/// keyed container that names eleven keys and reads only those, so a key it does not name is never
/// looked at.
private struct EntryBeforeF1016: Decodable {
    let id: UUID
    let date: Date
    let text: String
    let outcome: DictationLogEntry.Outcome
    let rawText: String?
    let refinement: String?
    let outcomeKind: String?
    let clipSeconds: Double?
    let transcribeSeconds: Double?
    let refineSeconds: Double?
    let gpuBusyPercent: Int?

    private enum CodingKeys: String, CodingKey {
        case id, date, text, outcome, rawText, refinement, outcomeKind
        case clipSeconds, transcribeSeconds, refineSeconds, gpuBusyPercent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        outcome = try container.decode(DictationLogEntry.Outcome.self, forKey: .outcome)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        refinement = try container.decodeIfPresent(String.self, forKey: .refinement)
        outcomeKind = try container.decodeIfPresent(String.self, forKey: .outcomeKind)
        clipSeconds = try? container.decodeIfPresent(Double.self, forKey: .clipSeconds)
        transcribeSeconds = try? container.decodeIfPresent(Double.self, forKey: .transcribeSeconds)
        refineSeconds = try? container.decodeIfPresent(Double.self, forKey: .refineSeconds)
        gpuBusyPercent = try? container.decodeIfPresent(Int.self, forKey: .gpuBusyPercent)
    }
}

private struct LogBeforeF1016: Decodable {
    let entries: [EntryBeforeF1016]
    let limit: Int
}

/// An entry as this build writes it for a cut-short Qwen dictation: pinned bytes, so the backward
/// direction is checked against what is on disk, not against whatever the encoder produces today.
private let cutShortEntry = """
{"id":"5E3A0000-0000-4000-8000-000000001016","date":781100000,"text":"我们的这个 Rem Let 这个",\
"outcome":{"pasted":{}},"clipSeconds":118,"transcribeSeconds":101.5,"truncated":true}
"""

@Test("An entry marked cut short decodes in the build before F1016, alone and inside a whole log")
func theBuildBeforeF1016ReadsACutShortEntry() throws {
    let old = try JSONDecoder().decode(EntryBeforeF1016.self, from: Data(cutShortEntry.utf8))
    #expect(old.text == "我们的这个 Rem Let 这个")
    #expect(old.outcome == .pasted)
    #expect(old.clipSeconds == 118)

    let log = "{\"entries\":[\(cutShortEntry),\(cutShortEntry)],\"limit\":100}"
    #expect(try JSONDecoder().decode(LogBeforeF1016.self, from: Data(log.utf8)).entries.count == 2)

    // And what this build writes, not only the pinned bytes.
    let written = try JSONEncoder().encode(DictationLog(entries: [
        DictationLogEntry(id: UUID(), date: Date(), text: "x", outcome: .pasted, truncated: true),
    ]))
    #expect(try JSONDecoder().decode(LogBeforeF1016.self, from: written).entries.first?.text == "x")
}

@Test("This build reads the mark off the pinned entry, and an entry from before F1016 is unmarked")
func thisBuildReadsTheCutShortMark() throws {
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(cutShortEntry.utf8))
    #expect(entry.truncated == true)
    #expect(entry.timings.clipSeconds == 118)

    let before = #"{"id":"3E3269A2-4E5B-4B0A-9A2E-111111111111","date":700000000,"text":"hello","outcome":{"pasted":{}},"rawText":"helo","refinement":"refined","clipSeconds":3}"#
    let old = try JSONDecoder().decode(DictationLogEntry.self, from: Data(before.utf8))
    #expect(old.truncated == nil)
    #expect(old.rawText == "helo")
}

@Test("The mark round-trips, and an entry that was not cut short writes no key (F1016)")
func theCutShortMarkRoundTripsAndIsAbsentOtherwise() throws {
    let entry = DictationLogEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_760_000_000),
                                  text: "partial", outcome: .clipboard, truncated: true)
    #expect(try JSONDecoder().decode(DictationLogEntry.self, from: JSONEncoder().encode(entry)) == entry)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let ordinary = DictationLogEntry(id: UUID(), date: Date(), text: "", outcome: .empty)
    let keys = try #require(JSONSerialization.jsonObject(with: encoder.encode(ordinary)) as? [String: Any]).keys
    #expect(Set(keys) == ["id", "date", "text", "outcome"])
}

@Test("A mark of the wrong type costs the mark, never the entry or the log (F1016)")
func aMalformedCutShortMarkCostsOnlyTheMark() throws {
    let odd = #"{"id":"3E3269A2-4E5B-4B0A-9A2E-222222222222","date":700000000,"text":"hi","outcome":{"pasted":{}},"truncated":"yes"}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(odd.utf8))
    #expect(entry.text == "hi")
    #expect(entry.truncated == nil)
}
