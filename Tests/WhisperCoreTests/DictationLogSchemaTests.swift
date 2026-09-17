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

// MARK: - F251: an unknown outcome must not take the log with it

@Test("An outcome case this build does not know decodes instead of throwing")
func unknownOutcomeDecodesLeniently() throws {
    // `Outcome` is an associated-value enum with synthesized `Codable`, so before F251 an outcome
    // written by a newer build threw `dataCorrupted` — and because `dictation-log.json` decodes as
    // one `DictationLog` value, that single entry made the WHOLE history unreadable. Same class of
    // bug as F188's meeting index, smaller blast radius.
    let fixture = #"{"discarded":{}}"#
    let outcome = try JSONDecoder().decode(
        DictationLogEntry.Outcome.self, from: Data(fixture.utf8)
    )
    // Mapped to `.failed`, carrying the case's own NAME. That keeps the decode honest — the entry
    // did not succeed as far as this build can tell — and preserves what the unknown case was
    // called, so the information is not silently destroyed the way a fallback to `.empty` would.
    guard case let .failed(reason) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(reason.contains("discarded"))
    #expect(reason.contains("newer version"))
}

@Test("One unknown outcome does not make the rest of the log unreadable")
func unknownOutcomeDoesNotPoisonTheWholeLog() throws {
    // The property that actually matters to a user: their dictation history survives.
    let fixture = """
    {"limit":100,"entries":[
      {"id":"3E3269A2-4E5B-4B0A-9A2E-111111111111","date":700000000,"text":"first","outcome":{"pasted":{}}},
      {"id":"3E3269A2-4E5B-4B0A-9A2E-222222222222","date":700000001,"text":"second","outcome":{"teleported":{}}},
      {"id":"3E3269A2-4E5B-4B0A-9A2E-333333333333","date":700000002,"text":"third","outcome":{"empty":{}}}
    ]}
    """
    let log = try JSONDecoder().decode(DictationLog.self, from: Data(fixture.utf8))
    #expect(log.entries.count == 3)
    #expect(log.entries.map(\.text) == ["first", "second", "third"])
    #expect(log.entries[0].outcome == .pasted)
    #expect(log.entries[2].outcome == .empty)
}

@Test("Every known outcome still decodes exactly, including failed's payload")
func knownOutcomesAreUnaffected() throws {
    let decoder = JSONDecoder()
    func decode(_ json: String) throws -> DictationLogEntry.Outcome {
        try decoder.decode(DictationLogEntry.Outcome.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"pasted":{}}"#) == .pasted)
    #expect(try decode(#"{"clipboard":{}}"#) == .clipboard)
    #expect(try decode(#"{"empty":{}}"#) == .empty)
    #expect(try decode(#"{"failed":{"_0":"disk full"}}"#) == .failed("disk full"))
}

@Test("The outcome wire shape is unchanged by the lenient decoder")
func outcomeWireShapeIsPinned() throws {
    // A hand-written `init(from:)` on an enum is exactly the kind of change that can silently
    // alter what `encode(to:)` produces. If these bytes ever change, every already-written
    // dictation-log.json on every user's Mac becomes unreadable — the failure this ticket exists to
    // prevent, caused by its own fix. The shape below was verified against a real on-disk log
    // (95 `{"pasted":{}}` and 5 `{"empty":{}}` entries).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func encode(_ outcome: DictationLogEntry.Outcome) throws -> String {
        try #require(String(data: encoder.encode(outcome), encoding: .utf8))
    }
    #expect(try encode(.pasted) == #"{"pasted":{}}"#)
    #expect(try encode(.clipboard) == #"{"clipboard":{}}"#)
    #expect(try encode(.empty) == #"{"empty":{}}"#)
    #expect(try encode(.failed("disk full")) == #"{"failed":{"_0":"disk full"}}"#)
}

@Test("An outcome object with no key at all is reported, not silently accepted")
func emptyOutcomeObjectStillThrows() {
    // Leniency is for values this build does not RECOGNISE, not for structurally broken JSON.
    // `{}` carries no case at all, which is corruption rather than a version skew.
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(DictationLogEntry.Outcome.self, from: Data("{}".utf8))
    }
}

@Test("An unknown sibling key beside a known case is tolerated, not rejected")
func unknownSiblingKeyIsTolerated() throws {
    // The forward-compatible direction, and the shape this leniency most needs to survive: the
    // likeliest next change to this type is a hand-written encoder that adds a key beside the case
    // (F250 prescribes exactly that). An earlier version of this decoder required exactly one key
    // and threw on this input, reintroducing the whole-log failure it was written to close.
    let outcome = try JSONDecoder().decode(
        DictationLogEntry.Outcome.self,
        from: Data(#"{"failed":{"_0":"disk full"},"note":"added by a newer build"}"#.utf8)
    )
    #expect(outcome == .failed("disk full"))
}

@Test("Two known cases at once is corruption and still throws")
func twoKnownCasesThrow() {
    // No encoder writes this, so it is damage rather than a version skew.
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            DictationLogEntry.Outcome.self,
            from: Data(#"{"pasted":{},"clipboard":{}}"#.utf8)
        )
    }
}

@Test("A failed payload is read by name, so extra payload keys cannot lose the reason")
func failedReasonIsReadByName() throws {
    let decoder = JSONDecoder()
    func decode(_ json: String) throws -> DictationLogEntry.Outcome {
        try decoder.decode(DictationLogEntry.Outcome.self, from: Data(json.utf8))
    }
    // The shape a future `case failed(String, Int)` would write. Reading `allKeys.first` here
    // returned the reason or "" AT RANDOM between processes; `_0` by name is deterministic.
    #expect(try decode(#"{"failed":{"_0":"real reason","_1":7}}"#) == .failed("real reason"))
    // Run it enough times that a nondeterministic read would be caught rather than fluked.
    for _ in 0..<50 {
        #expect(try decode(#"{"failed":{"_0":"real reason","_1":7}}"#) == .failed("real reason"))
    }
}

@Test("An unreadable failed payload says so instead of accusing with an empty reason")
func unreadableFailedPayloadGetsAPlaceholder() throws {
    let decoder = JSONDecoder()
    func decode(_ json: String) throws -> DictationLogEntry.Outcome {
        try decoder.decode(DictationLogEntry.Outcome.self, from: Data(json.utf8))
    }
    // `.failed("")` renders as "Failed: " in the dictation history — an accusation with no content.
    #expect(try decode(#"{"failed":{}}"#) == .failed("the reason could not be read"))
    #expect(try decode(#"{"failed":{"_0":123}}"#) == .failed("the reason could not be read"))
}

@Test("An unknown case with siblings names them deterministically")
func unknownCaseWithSiblingsIsDeterministic() throws {
    let decoder = JSONDecoder()
    let json = #"{"teleported":{},"note":"x"}"#
    let first = try decoder.decode(DictationLogEntry.Outcome.self, from: Data(json.utf8))
    // Sorted, so the recorded reason is the same on every machine and every run.
    guard case let .failed(reason) = first else {
        Issue.record("expected .failed, got \(first)")
        return
    }
    #expect(reason.contains("note, teleported"))
    for _ in 0..<50 {
        #expect(try decoder.decode(DictationLogEntry.Outcome.self, from: Data(json.utf8)) == first)
    }
}

// MARK: - F266: a leniently-decoded outcome must not be rewritten as a real failure

@Test("An unknown outcome keeps its true case name across a re-encode (F266)")
func unknownOutcomeSurvivesAReEncode() throws {
    // F251 stopped one entry making the whole log unreadable, but `DictationLogStore.persist()`
    // re-encodes the ENTIRE log on every `record()`. So after a downgrade plus a single dictation,
    // the unknown case was permanently rewritten on disk as a genuine failure — and the newer build
    // then showed a fabricated failure for that entry forever.
    let written = #"""
    {"date":761000000,"id":"5E3A0000-0000-4000-8000-000000000001",
     "outcome":{"discarded":{}},"text":"hello"}
    """#
    let decoder = JSONDecoder()
    let entry = try decoder.decode(DictationLogEntry.self, from: Data(written.utf8))

    // The true name is captured at decode time — there is nothing else to re-emit it from.
    #expect(entry.outcomeKind == "discarded")
    #expect(entry.text == "hello", "the dictated text must survive regardless")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let round = try decoder.decode(DictationLogEntry.self, from: encoder.encode(entry))
    #expect(round.outcomeKind == "discarded", "the case name was lost on the way back to disk")
    #expect(round.text == "hello")
}

@Test("A pre-F251 reader still finds a known case in `outcome` (F266)")
func oldBuildsStillDecodeTheEntry() throws {
    // The reason `outcome` keeps holding the nearest KNOWN case instead of the true one: a build
    // without F251's lenient decoder throws on an unrecognised case, and one such entry took the
    // whole log with it. Changing `outcome` to carry the true name would reintroduce exactly that
    // for every older build — the flag-day trap F188 records.
    let written = #"{"date":761000000,"id":"5E3A0000-0000-4000-8000-000000000002","outcome":{"discarded":{}},"text":"x"}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(written.utf8))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(data: encoder.encode(entry), encoding: .utf8))

    // `outcome` must still be a single-key object naming one of the four original cases.
    #expect(json.contains(#""outcome":{"failed":"#), "an old build could no longer read this entry")
    #expect(json.contains(#""outcomeKind":"discarded""#))
}

@Test("A known outcome writes no `outcomeKind` at all (F266)")
func knownOutcomesGainNoExtraKey() throws {
    // The field's PRESENCE is the signal that `outcome` is a degraded stand-in. Writing it for
    // every entry would make it redundant on ~100% of them and remove that meaning, as well as
    // changing the bytes of the common case for no benefit.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let entry = DictationLogEntry(
        id: UUID(uuidString: "5E3A0000-0000-4000-8000-000000000003")!,
        date: Date(timeIntervalSinceReferenceDate: 761_000_000),
        text: "ordinary",
        outcome: .pasted
    )
    let json = try #require(String(data: encoder.encode(entry), encoding: .utf8))
    #expect(!json.contains("outcomeKind"))
    #expect(json.contains(#""outcome":{"pasted":{}}"#))
}

@Test("A future build's own `outcomeKind` is preferred over the degraded outcome (F266)")
func outcomeKindWinsWhenBothArePresent() throws {
    // The shape this build writes is the shape a newer build will read back. When both are present
    // and disagree, the sibling is the truth and `outcome` is the stand-in.
    let written = #"""
    {"date":761000000,"id":"5E3A0000-0000-4000-8000-000000000004",
     "outcome":{"failed":{"_0":"Recorded by a newer version of WhisperMeet (discarded)."}},
     "outcomeKind":"discarded","text":"y"}
    """#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(written.utf8))
    #expect(entry.outcomeKind == "discarded")
    #expect(!entry.isSuccess)
    // And it is reported as a version skew rather than as something that went wrong.
    #expect(entry.wasRecordedByANewerBuild)
}

@Test("An unknown outcome is described as a newer build, not as a failure (F266)")
func unknownOutcomeIsNotShownAsAFailure() throws {
    let written = #"{"date":761000000,"id":"5E3A0000-0000-4000-8000-000000000005","outcome":{"queued":{}},"text":"z"}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(written.utf8))
    #expect(entry.wasRecordedByANewerBuild)

    // A real failure must not be mistaken for one.
    let genuine = DictationLogEntry(
        id: UUID(), date: Date(), text: "", outcome: .failed("disk full")
    )
    #expect(!genuine.wasRecordedByANewerBuild)
}
