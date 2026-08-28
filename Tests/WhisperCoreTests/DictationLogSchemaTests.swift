import Foundation
import Testing
@testable import WhisperCore

/// F200 changes the persisted `dictation-log.json` entry: two new OPTIONAL fields. Per the
/// persisted-schema rules these fixtures pin compatibility in BOTH directions (F188): an
/// already-shipped build's entry must decode in this build, and this build's entry must decode in
/// the shipped shape (extra keys ignored). The `outcome` wire shape (`{"pasted":{}}`) below was
/// verified against a real on-disk `dictation-log.json`.
private struct ShippedEntry: Codable {
    let id: UUID
    let date: Date
    let text: String
    let outcome: DictationLogEntry.Outcome
}

@Test("An old-format log entry (no refinement fields) decodes with nils")
func oldEntryDecodesForward() throws {
    let fixture = #"{"id":"3E3269A2-4E5B-4B0A-9A2E-111111111111","date":700000000,"text":"hello","outcome":{"pasted":{}}}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(fixture.utf8))
    #expect(entry.text == "hello")
    #expect(entry.outcome == .pasted)
    #expect(entry.rawText == nil)
    #expect(entry.refinement == nil)
}

@Test("A new-format entry still decodes in the shipped shape (backward direction)")
func newEntryDecodesBackward() throws {
    let entry = DictationLogEntry(
        id: UUID(), date: Date(), text: "Hello.", outcome: .pasted,
        rawText: "hello", refinement: DictationRefinement.refined.rawValue
    )
    let shipped = try JSONDecoder().decode(ShippedEntry.self, from: JSONEncoder().encode(entry))
    #expect(shipped.text == "Hello.")
    #expect(shipped.outcome == .pasted)
}

@Test("New fields round-trip")
func newFieldsRoundTrip() throws {
    let entry = DictationLogEntry(
        id: UUID(), date: Date(), text: "Hello.", outcome: .clipboard,
        rawText: "um hello", refinement: "rawTimeout"
    )
    let decoded = try JSONDecoder().decode(
        DictationLogEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded == entry)
}
