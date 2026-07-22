import Testing
import Foundation
@testable import WhisperCore

@Test("adding prepends and keeps most-recent-first")
func dictationLogAddingPrepends() {
    let log = DictationLog()
    let first = DictationLogEntry(id: UUID(), date: Date(), text: "first", outcome: .pasted)
    let second = DictationLogEntry(id: UUID(), date: Date(), text: "second", outcome: .pasted)
    let afterFirst = log.adding(first)
    let afterSecond = afterFirst.adding(second)
    #expect(afterSecond.entries.map(\.text) == ["second", "first"])
}

@Test("adding beyond limit drops the oldest")
func dictationLogAddingBeyondLimitDropsOldest() {
    let log = DictationLog(limit: 2)
    let a = DictationLogEntry(id: UUID(), date: Date(), text: "a", outcome: .pasted)
    let b = DictationLogEntry(id: UUID(), date: Date(), text: "b", outcome: .pasted)
    let c = DictationLogEntry(id: UUID(), date: Date(), text: "c", outcome: .pasted)
    let result = log.adding(a).adding(b).adding(c)
    #expect(result.entries.map(\.text) == ["c", "b"])
}

@Test("cleared empties the log")
func dictationLogClearedEmpties() {
    let log = DictationLog(entries: [
        DictationLogEntry(id: UUID(), date: Date(), text: "a", outcome: .pasted)
    ])
    #expect(log.cleared().entries.isEmpty)
}

@Test("Codable round-trip through JSONEncoder/JSONDecoder with iso8601 dates")
func dictationLogCodableRoundTrip() throws {
    // ISO 8601 (without fractional seconds) is the wire format, so seed with
    // whole-second dates to avoid losing sub-second precision on decode.
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let entries = [
        DictationLogEntry(id: UUID(), date: now, text: "ok", outcome: .pasted),
        DictationLogEntry(id: UUID(), date: now, text: "", outcome: .failed("network timeout"))
    ]
    let log = DictationLog(entries: entries, limit: 50)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(log)
    let decoded = try decoder.decode(DictationLog.self, from: data)

    #expect(decoded == log)
}

@Test("isSuccess is true for pasted and clipboard, false for empty and failed")
func dictationLogEntryIsSuccess() {
    let pasted = DictationLogEntry(id: UUID(), date: Date(), text: "x", outcome: .pasted)
    let clipboard = DictationLogEntry(id: UUID(), date: Date(), text: "x", outcome: .clipboard)
    let empty = DictationLogEntry(id: UUID(), date: Date(), text: "", outcome: .empty)
    let failed = DictationLogEntry(id: UUID(), date: Date(), text: "", outcome: .failed("oops"))

    #expect(pasted.isSuccess)
    #expect(clipboard.isSuccess)
    #expect(!empty.isSuccess)
    #expect(!failed.isSuccess)
}
