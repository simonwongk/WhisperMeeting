import Foundation
import Testing
@testable import WhisperCore

// F892 — the dictation history gains four optional fields, the figures F890 and F891 needed to
// tell why a dictation was slow: the clip's seconds, the recognizer's, the refiner's, and the GPU
// share before the request. `dictation-log.json` is a wire format every build a user might launch
// shares, so per the persisted-schema rules (F188) the fixtures run in both directions: an entry
// written before F892 decodes here with no timings, and the build before F892 reads an entry this
// one writes. The `Mirror`-derived check in `PersistedWireFormatTests` sees the new fields too.

/// `DictationLogEntry`'s decoder as it shipped at `ccb6abb`, the last build before F892, copied
/// key for key: a keyed container that names seven keys and reads only those, so a key it does not
/// name is never looked at. (The real thing was also compiled from `git show ccb6abb:…` and run
/// against a log this build wrote; see F892's log entry.)
private struct EntryBeforeF892: Decodable {
    let id: UUID
    let date: Date
    let text: String
    let outcome: DictationLogEntry.Outcome
    let rawText: String?
    let refinement: String?
    let outcomeKind: String?

    private enum CodingKeys: String, CodingKey {
        case id, date, text, outcome, rawText, refinement, outcomeKind
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
    }
}

/// `DictationLog` as it shipped at `ccb6abb`: synthesized, `entries` and `limit`.
private struct LogBeforeF892: Decodable {
    let entries: [EntryBeforeF892]
    let limit: Int
}

/// An entry as this build writes it when all four figures were measured — the 2026-10-08 19:40
/// dictation that reopened F891 (clip 4.00 s, transcribed in 6.93 s at 28 % GPU, refinement
/// rawTimeout about a second later). Pinned bytes, so the backward direction is checked against
/// what is on disk, not against whatever the encoder produces today.
private let entryWithTimings = """
{"id":"5E3A0000-0000-4000-8000-000000000892","date":781000000,"text":"Can you send me the report?",\
"outcome":{"pasted":{}},"refinement":"rawTimeout","clipSeconds":4,"transcribeSeconds":6.93,\
"refineSeconds":1.04,"gpuBusyPercent":28}
"""

@Test("An entry carrying timings decodes in the build before F892, alone and inside a whole log")
func theBuildBeforeF892ReadsAnEntryWithTimings() throws {
    let old = try JSONDecoder().decode(EntryBeforeF892.self, from: Data(entryWithTimings.utf8))
    #expect(old.text == "Can you send me the report?")
    #expect(old.outcome == .pasted)
    #expect(old.refinement == "rawTimeout")

    let log = "{\"entries\":[\(entryWithTimings),\(entryWithTimings)],\"limit\":100}"
    let oldLog = try JSONDecoder().decode(LogBeforeF892.self, from: Data(log.utf8))
    #expect(oldLog.entries.count == 2)

    // And what this build writes, not only the pinned bytes.
    let written = try JSONEncoder().encode(DictationLog(entries: [
        DictationLogEntry(
            id: UUID(), date: Date(), text: "x", outcome: .clipboard, refinement: "refined",
            timings: DictationTimings(clipSeconds: 1, transcribeSeconds: 2, refineSeconds: 3, gpuBusyPercent: 4)
        ),
    ]))
    #expect(try JSONDecoder().decode(LogBeforeF892.self, from: written).entries.first?.text == "x")
}

@Test("This build reads the timings off the pinned entry (F892)")
func thisBuildReadsTheTimings() throws {
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(entryWithTimings.utf8))
    #expect(entry.timings == DictationTimings(
        clipSeconds: 4, transcribeSeconds: 6.93, refineSeconds: 1.04, gpuBusyPercent: 28
    ))
    #expect(entry.text == "Can you send me the report?")
}

@Test("An entry written before F892 decodes with no timings (F892)")
func anEntryFromBeforeF892HasNoTimings() throws {
    // The shipped shape, as `oldEntryDecodesForward` pins it, plus F200's and F266's fields.
    let fixture = #"{"id":"3E3269A2-4E5B-4B0A-9A2E-111111111111","date":700000000,"text":"hello","outcome":{"pasted":{}},"rawText":"helo","refinement":"refined"}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(fixture.utf8))
    #expect(entry.timings == DictationTimings())
    #expect(entry.rawText == "helo")
}

@Test("Timings round-trip through the wire format (F892)")
func timingsRoundTrip() throws {
    let entry = DictationLogEntry(
        id: UUID(), date: Date(timeIntervalSince1970: 1_760_000_000), text: "Hello there.", outcome: .pasted,
        rawText: "hello there", refinement: "refined",
        timings: DictationTimings(clipSeconds: 3.25, transcribeSeconds: 0.31, refineSeconds: 0.72, gpuBusyPercent: 0)
    )
    let decoded = try JSONDecoder().decode(DictationLogEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded == entry)
    #expect(decoded.timings.gpuBusyPercent == 0, "an idle GPU is 0, which must not read as unmeasured")
}

@Test("The timing keys on the wire are pinned, and an unmeasured entry writes none of them (F892)")
func theTimingKeysArePinned() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let measured = DictationLogEntry(
        id: UUID(), date: Date(), text: "a", outcome: .pasted,
        timings: DictationTimings(clipSeconds: 1, transcribeSeconds: 2, refineSeconds: 3, gpuBusyPercent: 4)
    )
    let keys = try #require(JSONSerialization.jsonObject(with: encoder.encode(measured)) as? [String: Any]).keys
    #expect(Set(keys).isSuperset(of: ["clipSeconds", "transcribeSeconds", "refineSeconds", "gpuBusyPercent"]))

    // The common case before F892 — and a "nothing heard" now — keeps exactly its old bytes.
    let unmeasured = DictationLogEntry(id: UUID(), date: Date(), text: "", outcome: .empty)
    let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(unmeasured)) as? [String: Any]).keys
    #expect(Set(plain) == ["id", "date", "text", "outcome"])
}

@Test("A timing that is not a measurement costs that figure, never the entry or the log (F892)")
func aMalformedTimingCostsOnlyItself() throws {
    // A hand edit or a damaged file: a string where a number belongs, a negative duration, a
    // percentage past 100. Each is nil; the entry and the log beside it are intact.
    let bad = """
    {"id":"5E3A0000-0000-4000-8000-000000000893","date":781000000,"text":"kept","outcome":{"pasted":{}},\
    "clipSeconds":"long","transcribeSeconds":-2,"refineSeconds":{"x":1},"gpuBusyPercent":250}
    """
    let log = "{\"entries\":[\(bad),\(entryWithTimings)],\"limit\":100}"
    let decoded = try JSONDecoder().decode(DictationLog.self, from: Data(log.utf8))
    #expect(decoded.entries.count == 2)
    #expect(decoded.entries[0].text == "kept")
    #expect(decoded.entries[0].timings == DictationTimings())
    #expect(decoded.entries[1].timings.transcribeSeconds == 6.93)
}

@Test("A figure that cannot be a measurement is never stored, so the history can always be saved (F892)")
func impossibleFiguresAreNotStored() throws {
    let timings = DictationTimings(clipSeconds: .nan, transcribeSeconds: -0.5, refineSeconds: .infinity, gpuBusyPercent: 101)
    #expect(timings == DictationTimings())
    // JSONEncoder throws on NaN or infinity, which would fail the whole history's save.
    let entry = DictationLogEntry(id: UUID(), date: Date(), text: "a", outcome: .pasted, timings: timings)
    _ = try JSONEncoder().encode(DictationLog(entries: [entry]))
}

@Test("A figure set after construction goes through the same rule, so the history can still be saved (F892 review)")
func figuresSetAfterConstructionAreCheckedToo() throws {
    // The review's finding: the four fields were plain `public var`s, so a value assigned after
    // `init` skipped the rule, and one NaN in an entry made every later save of the history throw.
    var timings = DictationTimings(clipSeconds: 1, transcribeSeconds: 2, refineSeconds: 3, gpuBusyPercent: 4)
    timings.clipSeconds = .nan
    timings.transcribeSeconds = -1
    timings.refineSeconds = .infinity
    timings.gpuBusyPercent = 101
    #expect(timings == DictationTimings())

    timings.transcribeSeconds = 0.75 // and a real measurement set later is kept
    #expect(timings.transcribeSeconds == 0.75)

    let entry = DictationLogEntry(id: UUID(), date: Date(), text: "a", outcome: .pasted, timings: timings)
    _ = try JSONEncoder().encode(DictationLog(entries: [entry]))
}

// MARK: - The report

private func dated(_ seconds: TimeInterval, _ timings: DictationTimings, refinement: String? = nil,
                   text: String = "secret words",
                   outcome: DictationLogEntry.Outcome = .pasted) -> DictationLogEntry {
    DictationLogEntry(
        id: UUID(), date: Date(timeIntervalSince1970: seconds), text: text, outcome: outcome,
        refinement: refinement, timings: timings
    )
}

@Test("The slowest dictations are listed slowest first, by recognizer plus refiner (F892)")
func theSlowestDictationsComeFirst() throws {
    let log = DictationLog(entries: [
        dated(1_759_950_000, DictationTimings(clipSeconds: 3, transcribeSeconds: 0.37, gpuBusyPercent: 3)),
        dated(1_759_952_444, DictationTimings(clipSeconds: 4, transcribeSeconds: 6.93, refineSeconds: 1.04, gpuBusyPercent: 28),
              refinement: "rawTimeout"),
        dated(1_759_951_000, DictationTimings(clipSeconds: 48, transcribeSeconds: 2.84, refineSeconds: 0.6, gpuBusyPercent: 10),
              refinement: "refined"),
        dated(1_759_940_000, DictationTimings()), // from before F892: nothing measured, not listed
        // A recognizer that stopped answering after 30 s: the slowest of all, and it failed (review
        // finding b). Listed as failed; its reason is not printed, like the text.
        dated(1_759_953_000, DictationTimings(clipSeconds: 2, transcribeSeconds: 30, gpuBusyPercent: 0), text: "",
              outcome: .failed("Dictation helper stopped unexpectedly.")),
    ])
    let report = DictationTimingReport(log: log)
    let slowestFirst: [Double?] = [30, 6.93, 2.84, 0.37] // typed: Swift 6.1 infers a bare literal differently
    #expect(report.rows.map(\.timings.transcribeSeconds) == slowestFirst)

    let table = report.markdown(timeZone: try #require(TimeZone(identifier: "UTC")))
    #expect(table.contains("| 2025-10-08 19:50:00 | failed | 2.00 s | 30.00 s | — | 0 % | — |"))
    #expect(table.contains("| 2025-10-08 19:40:44 | pasted | 4.00 s | 6.93 s | 1.04 s | 28 % | rawTimeout |"))
    #expect(table.contains("| 2025-10-08 19:00:00 | pasted | 3.00 s | 0.37 s | — | 3 % | — |"))
    #expect(!table.contains("secret words"), "the report prints figures, never what was dictated")
    #expect(!table.contains("stopped unexpectedly"), "nor a failure's reason")

    #expect(DictationTimingReport(log: log, limit: 2).rows.count == 2)
    #expect(DictationTimingReport(log: log, since: Date(timeIntervalSince1970: 1_759_951_500)).rows.count == 2)
}

@Test("A log with no measured dictation says so instead of printing an empty table (F892)")
func noTimingsSaysSo() throws {
    let report = DictationTimingReport(log: DictationLog(entries: [dated(1_759_940_000, DictationTimings())]))
    #expect(report.rows.isEmpty)
    let text = report.markdown(timeZone: try #require(TimeZone(identifier: "UTC")))
    #expect(!text.contains("| when |"))
    #expect(text.contains("No dictation in this log recorded its timings"))
}
