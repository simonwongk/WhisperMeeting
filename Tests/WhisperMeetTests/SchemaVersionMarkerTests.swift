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

@Test("The marker is never read to make a decision, which is what keeps it a marker (F188)")
func markerIsNeverReadToMakeADecision() throws {
    // "Mark it" was chosen over "Flag day" on the reasoning that no format change can make an
    // already-shipped reader refuse. If production code ever branches on this value, the ticket's
    // claim of "marked, not fenced" silently becomes false. This is the assertion that fails first.
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
    var offenders: [String] = []
    let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        // `DiarizationArtifact` has its own, unrelated `schemaVersion`, and it genuinely **is** a
        // fence: it throws `malformed` on a mismatch. It can be, and this cannot, for a reason
        // worth keeping in view — that file is a sidecar this app wholly owns, and refusing it
        // costs one re-run of the analysis. Refusing `meetings.json` costs the user their library.
        // Same field name, opposite correct answer.
        guard url.lastPathComponent != "DiarizationArtifact.swift" else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.contains("schemaVersion"), !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
            // Declaring it, and stamping it, are the only permitted uses.
            let declares = code.contains("var schemaVersion") || code.contains("currentSchemaVersion =")
            let stamps = code.contains("schemaVersion = MeetingRecord.currentSchemaVersion")
            let names = code.contains("case ") && code.contains("schemaVersion")
            if !(declares || stamps || names) {
                offenders.append("\(url.lastPathComponent):\(number + 1): \(code)")
            }
        }
    }
    #expect(offenders.isEmpty, "the marker is being read, so it is no longer only a marker:\n\(offenders.joined(separator: "\n"))")
}
