import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F188 item 1 — "Mark it", the user's answer of 2026-09-19 to the three options in
// `docs/superpowers/specs/2026-09-17-schema-fence-design.md`.
//
// Each record carries the schema version its content was written against. **It is a marker, not a
// fence**, and the distinction is the whole point: an already-shipped reader ignores an unknown
// key, so it cannot refuse on one, and a future reader that checks the field does nothing for the
// readers that already exist. Downgrade protection stays F190's recoverable generations plus
// F188 item 3's instance guard, which does not exist yet.
//
// `markerIsNeverReadToMakeADecision` is the guard on that claim. The moment a reader branches on
// this field, "marked, not fenced" becomes false, and it becomes false invisibly — because the code
// that does it will look like an improvement.

private func unversionedIndexJSON(id: UUID, title: String = "old") -> String {
    """
    [{"id":"\(id.uuidString)","title":"\(title)","createdAt":"1992-03-08T09:46:40Z","duration":0,
      "recordingPath":"","status":"completed","transcriptText":"","segments":[]}]
    """
}

@MainActor
private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F188-marker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MeetingStore(rootDirectory: root), root)
}

@Test("A record written by this build carries the current schema version (F188)")
func newRecordsCarryTheSchemaVersion() throws {
    let record = MeetingRecord(id: UUID(), title: "new", status: .completed)
    #expect(record.schemaVersion == MeetingRecord.currentSchemaVersion)

    // And it reaches disk. `MeetingRecord` has a hand-written `CodingKeys`, so a new stored
    // property persists only if it was added there — the F304 trap, and the single likeliest way
    // for a version marker to end up quietly useless.
    //
    // Asserted on the **encoded bytes**, not on a round-trip. A round-trip cannot see this failure:
    // with the key missing from `CodingKeys`, `encode` omits it and the synthesized `init(from:)`
    // falls back to the property's declared default, so the value comes back correct having never
    // been written. This test WAS a round-trip when first written and passed with the key removed —
    // its own comment claimed a guarantee it did not provide, which is the defect this ticket keeps
    // producing. `everyStoredFieldIsEncoded` catches it too, from the other direction.
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
    #expect(wire?["schemaVersion"] as? Int == MeetingRecord.currentSchemaVersion,
            "the marker never reached the wire, so nothing on disk would carry it")
    let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
    #expect(restored.schemaVersion == MeetingRecord.currentSchemaVersion)
}

// These fixtures go through a PLAIN `JSONDecoder`, whose default date strategy is a Double —
// unlike the store's, which is `.iso8601`. Same JSON is not readable by both.
@Test("An index written before the marker existed decodes as unversioned, not as current (F188)")
func olderIndexDecodesAsUnversioned() throws {
    // The absent-key case specifically. A default value on the property would make this read as
    // "written by this build", which is the one thing a version marker must never claim falsely —
    // and Swift's synthesized decoder ignores a property's default anyway, so asserting it here is
    // what keeps the field optional if someone later tries to make it required.
    let absent = """
    {"id":"\(UUID().uuidString)","title":"old","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[]}
    """
    #expect(try JSONDecoder().decode(MeetingRecord.self, from: Data(absent.utf8)).schemaVersion == nil)

    // The null trap: `"schemaVersion": null` decodes to nil WITHOUT throwing, so a fixture emitting
    // null looks like it covers the absent case and does not. Both are pinned so neither can stand
    // in for the other.
    let explicitNull = """
    {"id":"\(UUID().uuidString)","title":"old","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[],"schemaVersion":null}
    """
    #expect(try JSONDecoder().decode(MeetingRecord.self, from: Data(explicitNull.utf8)).schemaVersion == nil)

    // A version this build has never heard of decodes too — it is data, not a gate.
    let future = """
    {"id":"\(UUID().uuidString)","title":"future","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[],"schemaVersion":99}
    """
    #expect(try JSONDecoder().decode(MeetingRecord.self, from: Data(future.utf8)).schemaVersion == 99)
}

@MainActor
@Test("Editing an unversioned record marks it; leaving it alone does not (F188)")
func editingAnOldRecordMarksIt() throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let edited = UUID(), untouched = UUID()
    let json = """
    [{"id":"\(edited.uuidString)","title":"edited","createdAt":"1992-03-08T09:46:40Z","duration":0,
      "recordingPath":"","status":"completed","transcriptText":"","segments":[]},
     {"id":"\(untouched.uuidString)","title":"untouched","createdAt":"1992-03-08T09:46:40Z","duration":0,
      "recordingPath":"","status":"completed","transcriptText":"","segments":[]}]
    """
    try Data(json.utf8).write(to: root.appendingPathComponent("meetings.json"))
    let reopened = MeetingStore(rootDirectory: root)
    try #require(!reopened.isDegraded)
    #expect(reopened.meeting(id: edited)?.schemaVersion == nil, "loaded as written, not as current")

    reopened.update(id: edited) { $0.title = "now edited" }

    #expect(reopened.meeting(id: edited)?.schemaVersion == MeetingRecord.currentSchemaVersion)
    // The version describes the record's content, not the file: a record nobody touched keeps
    // saying what it was written against, even though the file around it was just rewritten.
    #expect(reopened.meeting(id: untouched)?.schemaVersion == nil)

    // Which means one file holds records at mixed versions, and that is normal. "The index's
    // version" is not a well-formed question — only "this record's version" is. Anyone reaching for
    // the former will be tempted by an envelope, which is option A arriving by the back door.
    // The store writes dates as ISO8601, so reading its file back needs a decoder configured the
    // same way — a plain one throws on `createdAt`.
    let storeDecoder = JSONDecoder()
    storeDecoder.dateDecodingStrategy = .iso8601
    let onDisk = try storeDecoder.decode(
        [MeetingRecord].self, from: Data(contentsOf: root.appendingPathComponent("meetings.json"))
    )
    #expect(Set(onDisk.map { $0.schemaVersion }) == [MeetingRecord.currentSchemaVersion, nil])
    _ = store
}

// F441 part 4 — the guard used to let a line through on two loose tests: `code.contains("case ")` together
// with `schemaVersion` (meant for the CodingKeys `case schemaMarker = "schemaVersion"`), and any line that
// merely contained `var schemaVersion`. So `if case let v? = record.schemaVersion, v > 1 { … }` and
// `var schemaVersionIsNewer = record.schemaVersion ?? 0 > 1` both passed while production branched on
// the marker — measured by injecting exactly those two lines into `MeetingStore.update` and watching the old
// guard stay green. Every permitted use is now a WHOLE line matching one exact shape, so a line that
// does something else with the marker is an offender whatever words it happens to contain.

/// Every shape of line that may mention the marker, anchored at both ends.
private let permittedMarkerLines: [(name: String, pattern: String)] = [
    // The constant this build writes, and the record's two views of the marker.
    ("declaration of the current version", #"^static let currentSchemaVersion = [0-9]+$"#),
    ("the public accessor's declaration", #"^var schemaVersion: Int\? \{$"#),
    ("the accessor's getter", #"^get \{ schemaMarker\?\.version \}$"#),
    ("the accessor's setter", #"^set \{ schemaMarker = newValue\.map\(SchemaMarker\.init\) \}$"#),
    ("the stored form", #"^private var schemaMarker: SchemaMarker\? = SchemaMarker\(MeetingRecord\.currentSchemaVersion\)$"#),
    ("the stored form's type", #"^struct SchemaMarker: Codable, Equatable, Sendable \{$"#),
    // The on-disk key.
    ("the coding key", #"^case schemaMarker = "schemaVersion"$"#),
    ("the plain coding key", #"^case schemaVersion$"#),
    // Stamping: a write of this build's version onto a record the build just wrote, and nothing else.
    ("a stamp", #"^[A-Za-z_][A-Za-z0-9_]*(\[[A-Za-z_][A-Za-z0-9_]*\])?\.schemaVersion = MeetingRecord\.currentSchemaVersion$"#),
]

/// F552's lowering: the one place the value decides anything, and what it decides is what the WRITER vouches
/// for, never how a reader treats the record. Counted, so a second site is a decision somebody has to make
/// here rather than slip in.
private let markerLoweringLine = #"^try container\.encode\(min\(version, MeetingRecord\.currentSchemaVersion\)\)$"#

private func lineMatches(_ line: String, _ pattern: String) -> Bool {
    line.range(of: pattern, options: .regularExpression) != nil
}

/// Scans one file's comment-stripped source for lines that mention the marker without being a permitted shape.
private func markerUses(in source: String, fileName: String) -> (offenders: [String], lowerings: [String]) {
    var offenders: [String] = []
    var lowerings: [String] = []
    for (number, line) in SourceAssertion.numbered(source) {
        let code = line.trimmingCharacters(in: .whitespaces)
        // Case-insensitive on purpose: `currentSchemaVersion` and `SchemaMarker` are the marker's names too,
        // and a decision made from either is the same decision.
        let lowered = code.lowercased()
        guard lowered.contains("schemaversion") || lowered.contains("schemamarker") else { continue }
        if lineMatches(code, markerLoweringLine) {
            lowerings.append("\(fileName):\(number)")
        } else if !permittedMarkerLines.contains(where: { lineMatches(code, $0.pattern) }) {
            offenders.append("\(fileName):\(number): \(code)")
        }
    }
    return (offenders, lowerings)
}

@Test("The marker is never read to make a decision, which is what keeps it a marker (F188)")
func markerIsNeverReadToMakeADecision() throws {
    // "Mark it" was chosen over "Flag day" on the reasoning that no format change can make an
    // already-shipped reader refuse. If production code ever branches on this value, the ticket's
    // claim of "marked, not fenced" silently becomes false. This is the assertion that fails first.
    var offenders: [String] = []
    var lowerings: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        let text = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
        // `DiarizationArtifact` has its own, unrelated `schemaVersion`, and it genuinely **is** a
        // fence: it throws `malformed` on a mismatch. It can be, and this cannot, for a reason
        // worth keeping in view — that file is a sidecar this app wholly owns, and refusing it
        // costs one re-run of the analysis. Refusing `meetings.json` costs the user their library.
        // Same field name, opposite correct answer. The exemption is that file's own property, so it
        // holds only while the file has nothing to do with meetings: a read of a meeting's marker
        // cannot hide in it.
        if url.lastPathComponent == "DiarizationArtifact.swift" {
            #expect(!text.contains("MeetingRecord") && !text.contains("meetings.json"),
                    "DiarizationArtifact.swift is exempt as a separate sidecar; it now mentions meetings")
            continue
        }
        let found = markerUses(in: text, fileName: url.lastPathComponent)
        offenders += found.offenders
        lowerings += found.lowerings
    }
    #expect(offenders.isEmpty, "the marker is being read, so it is no longer only a marker:\n\(offenders.joined(separator: "\n"))")
    #expect(lowerings.count == 1, "the encoder's lowering is the one sanctioned use (F552): \(lowerings)")
}

// F441 part 4 — the guard itself, proven able to fail. A guard over source text cannot be shown to work
// by the real tree staying clean, so these run it over snippets: the decisions it must refuse, and the
// uses it must allow.
@Test("The marker guard refuses every way of reading the marker and allows the sanctioned shapes (F441)")
func markerGuardCanFail() {
    let decisions = [
        "if case let v? = record.schemaVersion, v > 1 { return }",
        "var schemaVersionIsNewer = record.schemaVersion ?? 0 > 1",
        "let newer = (record.schemaVersion ?? 0) > MeetingRecord.currentSchemaVersion",
        "guard record.schemaVersion == nil else { continue }",
        "switch meeting.schemaVersion { case 1?: break default: break }",
        "if record.schemaVersion == MeetingRecord.currentSchemaVersion { x() }",
        "var currentSchemaVersion = record.schemaVersion",
        "let isCurrent = a.currentSchemaVersion == b",
        "case let schemaVersion = v",
        "let m = record.schemaMarker",
        // The lowering, altered: still the marker, no longer the sanctioned shape.
        "try container.encode(min(version, MeetingRecord.currentSchemaVersion + 1))",
        // A stamp with something else going on in the same line is a decision about when to stamp.
        "if flag { record.schemaVersion = MeetingRecord.currentSchemaVersion }",
    ]
    for line in decisions {
        let found = markerUses(in: line, fileName: "Synthetic.swift")
        #expect(!found.offenders.isEmpty, "the guard let a marker decision through: \(line)")
    }

    let sanctioned = [
        "static let currentSchemaVersion = 2",
        "var schemaVersion: Int? {",
        "get { schemaMarker?.version }",
        "set { schemaMarker = newValue.map(SchemaMarker.init) }",
        "private var schemaMarker: SchemaMarker? = SchemaMarker(MeetingRecord.currentSchemaVersion)",
        "struct SchemaMarker: Codable, Equatable, Sendable {",
        "case schemaMarker = \"schemaVersion\"",
        "meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion",
        "record.schemaVersion = MeetingRecord.currentSchemaVersion",
    ]
    for line in sanctioned {
        let found = markerUses(in: line, fileName: "Synthetic.swift")
        #expect(found.offenders.isEmpty, "the guard refused a sanctioned shape: \(line)")
    }

    let lowering = markerUses(
        in: "try container.encode(min(version, MeetingRecord.currentSchemaVersion))", fileName: "Synthetic.swift"
    )
    #expect(lowering.offenders.isEmpty)
    #expect(lowering.lowerings == ["Synthetic.swift:1"])
}
