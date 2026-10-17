import Foundation
import Testing
@testable import WhisperCore

// F907 — the week-later shred spent 4.6 s per 274 MB index generation in `JSONArrayShred`, which
// parsed every element of every generation and pretty-printed all of it again, four times per shred:
// 18.7 s on the main actor at launch for a 1,000-meeting library. The shred now finds the array's
// elements by their bytes, parses only the elements whose bytes mention a deleted id, and keeps every
// other element byte for byte. Anything it cannot vouch for takes the whole-parse path it replaced.
//
// The oracle is that replaced implementation, kept here verbatim: for every input, the new answer must
// parse to the same array, remove the same ids and report the same count — or be nil exactly when the
// old one was.

/// The pre-F907 implementation, as the oracle.
private func reference(_ ids: Set<String>, _ data: Data) -> (data: Data, count: Int, removed: Set<String>)? {
    let doomed = Set(ids.map { $0.lowercased() })
    guard !doomed.isEmpty,
          let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    else { return nil }
    var removed: Set<String> = []
    let kept = elements.filter { element in
        guard let id = (element as? [String: Any])?["id"] as? String,
              doomed.contains(id.lowercased())
        else { return true }
        removed.insert(id.lowercased())
        return false
    }
    guard !removed.isEmpty,
          let rewritten = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return (rewritten, kept.count, removed)
}

private func parsed(_ data: Data) -> NSArray? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSArray
}

/// The new answer agrees with the oracle's, in meaning.
private func expectAgrees(_ ids: Set<String>, _ data: Data, _ label: String,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let old = reference(ids, data)
    let new = JSONArrayShred.removingElements(withIDs: ids, from: data)
    #expect((old == nil) == (new == nil), "\(label): one answered nil and the other did not", sourceLocation: sourceLocation)
    guard let old, let new else { return }
    #expect(new.count == old.count, "\(label): count", sourceLocation: sourceLocation)
    #expect(new.removed == old.removed, "\(label): removed", sourceLocation: sourceLocation)
    let newValue = parsed(new.data)
    #expect(newValue != nil, "\(label): the output is not a JSON array", sourceLocation: sourceLocation)
    #expect(newValue == parsed(old.data), "\(label): the output means something else", sourceLocation: sourceLocation)
}

private struct Segment: Codable {
    var id: String?
    var text: String
}

private struct Record: Codable {
    var id: String
    var title: String
    var transcriptText: String
    var segments: [Segment]
    var duration: Double
    var tags: [String]?
}

/// Bytes as the stores write them: `JSONEncoder`, pretty-printed, sorted keys.
private func storeBytes(_ records: [Record]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(records)
}

private let a = "6F1E7C2A-9B53-4C8E-A0D1-3E5F7A9B1C2D"
private let b = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"
private let c = "FFFFEEEE-DDDD-CCCC-BBBB-AAAA99998888"

private func library() -> [Record] {
    [
        Record(id: a, title: "Standup [daily] {notes}", transcriptText: "he said \"stop\" \\ then ] and }",
               segments: [Segment(id: nil, text: "x")], duration: 0.1, tags: ["a,b"]),
        // Mentions `a` in its text and as a nested id, and is not `a`.
        Record(id: b, title: "Mentions \(a.lowercased())", transcriptText: "see \(a)",
               segments: [Segment(id: a, text: "nested id, not the record's")], duration: 1e-7, tags: nil),
        Record(id: c, title: "Unicode — 会议 \u{1F600}", transcriptText: "tab\tnewline\n", segments: [],
               duration: 12_345.678_9, tags: []),
    ]
}

@Test("A store-written array loses exactly the records named, as the whole-parse shred did (F907)")
func shredAgreesWithTheWholeParseOnStoreBytes() throws {
    let data = try storeBytes(library())
    expectAgrees([a], data, "one record, upper case")
    expectAgrees([a.lowercased()], data, "asked in lower case")
    expectAgrees([a, c], data, "two records")
    expectAgrees([a, b, c], data, "every record")
    expectAgrees([UUID().uuidString], data, "an id no record has")
    expectAgrees([], data, "no ids")
}

@Test("An id that is only mentioned, or is only a nested id, does not remove the record (F907)")
func mentionIsNotARecord() throws {
    let data = try storeBytes(Array(library().dropFirst()))
    let shred = JSONArrayShred.removingElements(withIDs: [a], from: data)
    #expect(shred == nil, "a record that only mentions the id was removed")
}

@Test("Every record the shred keeps is kept byte for byte (F907)")
func keptRecordsAreByteIdentical() throws {
    let records = library()
    let data = try storeBytes(records)
    let shred = try #require(JSONArrayShred.removingElements(withIDs: [b], from: data))
    // The store's encoder formats each element on its own, so the file it would write for the
    // records that are left is exactly the old file with one element taken out.
    let expected = try storeBytes([records[0], records[2]])
    #expect(shred.data == expected,
            "kept records were rewritten:\n\(String(decoding: shred.data, as: UTF8.self))")
}

@Test("Hand-written and odd arrays get the same answer as the whole-parse shred (F907)")
func oddInputsAgree() {
    let cases: [(String, String)] = [
        ("compact", #"[{"id":"\#(a)","x":1},{"id":"\#(b)"}]"#),
        ("mixed-case id in the file", #"[{"id":"\#(a.lowercased().capitalized)"},{"id":"\#(b)"}]"#),
        ("the same id twice", #"[{"id":"\#(a)"},{"id":"\#(b)"},{"id":"\#(a)"}]"#),
        ("non-object elements", #"[1, "\#(a)", null, [ "\#(a)" ], {"id":"\#(a)"}, true]"#),
        ("id that is not a string", #"[{"id": 7, "t": "\#(a)"}, {"id":"\#(a)"}]"#),
        ("escaped quotes and brackets in strings", #"[{"t":"a \"]\" b \\","id":"\#(a)"},{"id":"\#(b)","t":"}{]["}]"#),
        ("unicode escapes", #"[{"id":"\#(a)","t":"\u005d\u0022"},{"id":"\#(b)"}]"#),
        ("whitespace everywhere", " \n\t[ \n {\"id\" : \"\(a)\" } ,\n\t{\"id\":\"\(b)\"}\n ] \n"),
        ("only the doomed record", #"[{"id":"\#(a)"}]"#),
        ("empty array", "[]"),
        ("a top-level object", #"{"id":"\#(a)"}"#),
        ("torn", #"[{"id":"\#(a)"},{"id":"\#(b)","t":"cut he"#),
        ("trailing garbage", #"[{"id":"\#(a)"}] x"#),
        ("a doomed record that does not parse", #"[{"id":"\#(a)","t": tru},{"id":"\#(b)"}]"#),
        ("an unrelated record that does not parse", #"[{"id":"\#(a)"},{"id":"\#(b)","t": tru}]"#),
        ("trailing comma", #"[{"id":"\#(a)"},{"id":"\#(b)"},]"#),
        ("missing comma", #"[{"id":"\#(a)"} {"id":"\#(b)"}]"#),
        ("mismatched brackets", #"[{"id":"\#(a)"],{"id":"\#(b)"}]"#),
        ("byte order mark", "\u{FEFF}[{\"id\":\"\(a)\"},{\"id\":\"\(b)\"}]"),
    ]
    for (label, text) in cases {
        expectAgrees([a], Data(text.utf8), label)
    }
}

@Test("Removing every record still writes a JSON array (F907)")
func removingEverythingLeavesAnEmptyArray() throws {
    let data = try storeBytes(library())
    let shred = try #require(JSONArrayShred.removingElements(withIDs: [a, b, c], from: data))
    #expect(shred.count == 0)
    #expect(parsed(shred.data) == NSArray())
}
