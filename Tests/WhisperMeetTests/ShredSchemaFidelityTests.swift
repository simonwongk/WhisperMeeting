import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F552 — what this build writes over data a NEWER build wrote.
//
// Part 1. F295's shred re-recorded every retained generation that held a deleted meeting by
// decoding it as this build's `[MeetingRecord]` and encoding it again. That is lossy for anything a
// newer build wrote — a field this build has never heard of is dropped, a status it does not know is
// rewritten as `recorded` — and those generations are exactly the copies F188 relies on to undo a
// downgrade. A generation this build could not decode at all was skipped, so the deleted meeting's
// text stayed in it: a privacy miss, in the one file the shred exists to clean. The shred now works
// on the JSON itself: it removes the deleted elements and leaves every other byte's meaning alone.
//
// Part 2. `schemaVersion` says which schema a record's content was written against. A record a newer
// build wrote and this build re-saved kept the newer number while this build dropped what it could
// not represent — the "wrong marker" F188's own doc calls worse than none. This build now writes the
// smaller of the stored marker and its own, because the content on disk is at most what it can
// represent.
//
// Fixtures in both directions (F188): a newer build's data processed here, and this build's output
// read by an older build.

private let week = Int(MeetingStore.shredGracePeriod)

/// A meeting as a NEWER build writes it: every key this build requires, plus a field it has never
/// heard of (`chapters`), a status it does not know (`archived`) and a schema version past its own.
/// `transcriptText` is optional only so one generation can be written that this build cannot decode.
private struct NewerBuildMeeting: Codable {
    var id: String
    var title: String
    var createdAt = "2026-09-01T10:00:00Z"
    var duration: Double = 0
    var recordingPath = ""
    var status = "archived"
    var transcriptText: String? = "text"
    var segments: [String] = []
    var schemaVersion = MeetingRecord.currentSchemaVersion + 1
    var chapters = ["Intro", "Budget"]
}

/// The newer build's own store over the same files: real F190 generations, ledger and backup.
/// Retention is widened only so the fixture's older generations survive its own saves.
private func newerBuildStore(_ root: URL) -> BackupJSONStore<[NewerBuildMeeting]> {
    BackupJSONStore<[NewerBuildMeeting]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "a0a0a0a0",
        retention: RetentionPolicy(recentCount: 100),
        recordCount: { $0.count }
    )
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F552-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Every top-level element of every retained generation, by file name.
private func historyElements(_ root: URL) throws -> [String: [[String: Any]]] {
    let directory = root.appendingPathComponent("meetings.history")
    var out: [String: [[String: Any]]] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name.hasPrefix("g-") {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        out[name] = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    return out
}

private func elements(of url: URL) throws -> [[String: Any]] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
}

/// The newer build writes five generations and deletes the secret meeting in the fourth; the shred
/// is queued with a date past the grace window. `deleteIsLastSave` leaves the delete as the most
/// recent save, so the backup copy still holds the secret.
private struct NewerBuildLibrary {
    let root: URL
    let secret: UUID
    let keep: UUID
    let other: UUID
}

private func makeNewerBuildLibrary(_ label: String, deleteIsLastSave: Bool) throws -> NewerBuildLibrary {
    let root = try makeRoot(label)
    let secret = UUID(), keep = UUID(), other = UUID()
    let store = newerBuildStore(root)
    let a = NewerBuildMeeting(id: keep.uuidString, title: "Standup")
    let s = NewerBuildMeeting(id: secret.uuidString, title: "Board review confidential-kestrel")
    let b = NewerBuildMeeting(id: other.uuidString, title: "Planning")
    var aWithoutText = a
    aWithoutText.transcriptText = nil     // this build requires the key, so it cannot decode this one
    var sLowercased = s
    sLowercased.id = secret.uuidString.lowercased()   // `UUID(uuidString:)` reads either spelling

    try store.save([a])
    // The largest generation, so retention pins it whatever else is pruned — and one this build
    // cannot decode, which is where a typed shred left the deleted meeting's text behind.
    try store.save([aWithoutText, s, NewerBuildMeeting(id: UUID().uuidString, title: "Retro"),
                    NewerBuildMeeting(id: UUID().uuidString, title: "One-on-one")],
                   expecting: try store.load()?.token)
    try store.save([a, sLowercased, b], expecting: try store.load()?.token)
    try store.save([a, b], expecting: try store.load()?.token)   // the delete
    if !deleteIsLastSave {
        var retitled = b
        retitled.title = "Planning, retitled"
        try store.save([a, retitled], expecting: try store.load()?.token)
    }
    // The newer build queued the shred when it deleted; it is now past due.
    let due = Int(Date().timeIntervalSince1970) - week - 60
    try Data(#"{"\#(secret.uuidString)":\#(due)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))
    return NewerBuildLibrary(root: root, secret: secret, keep: keep, other: other)
}

@MainActor
@Test("A shred keeps what a newer build wrote in every generation, and reaches the ones this build cannot decode (F552)")
func shredKeepsNewerBuildFieldsInHistory() throws {
    let library = try makeNewerBuildLibrary("history", deleteIsLastSave: false)
    defer { try? FileManager.default.removeItem(at: library.root) }
    let primaryBefore = try Data(contentsOf: library.root.appendingPathComponent("meetings.json"))
    let store = MeetingStore(rootDirectory: library.root)
    try #require(!store.isDegraded)
    try #require(store.meetings.count == 2)

    #expect(store.processPendingShreds() == [library.secret])

    let history = try historyElements(library.root)
    #expect(history.count == 5, "the fixture's five generations, re-recorded rather than added to: \(history.keys.sorted())")
    for (name, records) in history {
        // Privacy first: every generation, including the one this build cannot decode.
        #expect(!records.contains { ($0["title"] as? String)?.contains("confidential-kestrel") == true },
                "\(name) still holds the deleted meeting")
        // Fidelity: what the newer build wrote is still there, as it wrote it.
        for record in records {
            #expect(record["chapters"] as? [String] == ["Intro", "Budget"], "\(name) lost a newer build's field")
            #expect(record["status"] as? String == "archived", "\(name) rewrote a status this build does not know")
            #expect(record["schemaVersion"] as? Int == MeetingRecord.currentSchemaVersion + 1,
                    "\(name) changed the marker of a record it did not re-encode")
        }
    }
    // The backup no longer held the deleted meeting, so nothing needed rotating: the live index
    // the newer build wrote is not re-encoded just because a shred happened.
    #expect(try Data(contentsOf: library.root.appendingPathComponent("meetings.json")) == primaryBefore,
            "the live index was rewritten through this build's model")
    #expect(store.pendingShreds.isEmpty)
}

@MainActor
@Test("When the backup still holds the deleted meeting it is rotated out, and what this build re-saved is marked as its own (F552)")
func rotationOverNewerBuildDataIsHonestlyMarked() throws {
    let library = try makeNewerBuildLibrary("rotation", deleteIsLastSave: true)
    defer { try? FileManager.default.removeItem(at: library.root) }
    let store = MeetingStore(rootDirectory: library.root)
    try #require(!store.isDegraded)
    let backupURL = library.root.appendingPathComponent("meetings.backup.json")
    try #require(String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"))

    #expect(store.processPendingShreds() == [library.secret])

    #expect(!String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"),
            "the backup copy still holds the deleted meeting")
    // Rotating means one ordinary save of the live value by this build, which cannot represent
    // `chapters`. The marker must then say this build, not the newer one: the content is at most
    // what this build can hold.
    let primary = try elements(of: library.root.appendingPathComponent("meetings.json"))
    try #require(primary.count == 2)
    try #require(primary.allSatisfy { $0["chapters"] == nil }, "fixture: this build cannot carry `chapters`")
    for record in primary {
        #expect(record["schemaVersion"] as? Int == MeetingRecord.currentSchemaVersion,
                "a record re-saved without the newer build's fields still claims the newer schema")
    }
    // And the store keeps saving: it adopted the rotation's generation.
    store.update(id: library.keep) { $0.title = "Standup, edited" }
    #expect(store.writeConflict == nil)
    #expect(MeetingStore(rootDirectory: library.root).meeting(id: library.keep)?.title == "Standup, edited")
}

@MainActor
@Test("An ordinary save marks a newer build's untouched record with this build's schema version (F552)")
func ordinarySaveLowersANewerMarker() throws {
    let root = try makeRoot("save")
    defer { try? FileManager.default.removeItem(at: root) }
    let edited = UUID(), untouched = UUID()
    try newerBuildStore(root).save([
        NewerBuildMeeting(id: edited.uuidString, title: "Edited here"),
        NewerBuildMeeting(id: untouched.uuidString, title: "Never touched here"),
    ])
    let store = MeetingStore(rootDirectory: root)
    try #require(!store.isDegraded)
    // In memory the marker is still what was read: it is data, not a gate (F188).
    #expect(store.meeting(id: untouched)?.schemaVersion == MeetingRecord.currentSchemaVersion + 1)

    // Any edit re-saves the whole index, the untouched record included.
    store.update(id: edited) { $0.title = "Edited here, again" }

    let onDisk = try elements(of: root.appendingPathComponent("meetings.json"))
    let record = try #require(onDisk.first { ($0["id"] as? String) == untouched.uuidString })
    #expect(record["chapters"] == nil, "fixture: this build cannot carry the newer build's field")
    #expect(record["schemaVersion"] as? Int == MeetingRecord.currentSchemaVersion,
            "a record this build re-saved without the newer build's fields still claims the newer schema")
}

/// An index this build has always written — its own marker, or none — is written exactly as before.
@MainActor
@Test("A record at or below this build's schema keeps its marker through a save (F552, F188)")
func olderMarkersAreWrittenUnchanged() throws {
    let root = try makeRoot("older")
    defer { try? FileManager.default.removeItem(at: root) }
    let unversioned = UUID(), current = UUID()
    let json = """
    [{"id":"\(unversioned.uuidString)","title":"old","createdAt":"1992-03-08T09:46:40Z","duration":0,
      "recordingPath":"","status":"completed","transcriptText":"","segments":[]},
     {"id":"\(current.uuidString)","title":"current","createdAt":"1992-03-08T09:46:40Z","duration":0,
      "recordingPath":"","status":"completed","transcriptText":"","segments":[],"schemaVersion":\(MeetingRecord.currentSchemaVersion)}]
    """
    try Data(json.utf8).write(to: root.appendingPathComponent("meetings.json"))
    let store = MeetingStore(rootDirectory: root)
    try #require(!store.isDegraded)

    store.upsert(MeetingRecord(id: UUID(), title: "new", status: .completed))

    let onDisk = try elements(of: root.appendingPathComponent("meetings.json"))
    #expect(onDisk.first { ($0["id"] as? String) == unversioned.uuidString }?["schemaVersion"] == nil,
            "an unversioned record gained a marker it was never written under")
    #expect(onDisk.first { ($0["id"] as? String) == current.uuidString }?["schemaVersion"] as? Int
            == MeetingRecord.currentSchemaVersion)
}

/// The other direction: what this build leaves behind after a shred is read by an older build —
/// here the shape every build before F188 decoded, which requires these keys and ignores the rest.
private struct PreF188Meeting: Decodable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let recordingPath: String
    let status: String
    let transcriptText: String
    let segments: [TranscriptSegment]
}

@MainActor
@Test("An older build still reads every generation and the index this build leaves after a shred (F552)")
func olderBuildReadsWhatTheShredLeaves() throws {
    let library = try makeNewerBuildLibrary("older-reader", deleteIsLastSave: true)
    defer { try? FileManager.default.removeItem(at: library.root) }
    let store = MeetingStore(rootDirectory: library.root)
    try #require(store.processPendingShreds() == [library.secret])

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let directory = library.root.appendingPathComponent("meetings.history")
    var checked = 0
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("g-") {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        // The one generation the fixture deliberately wrote without `transcriptText` never decoded
        // anywhere; every other one must.
        guard !(try elements(of: directory.appendingPathComponent(name))).contains(where: { $0["transcriptText"] == nil })
        else { continue }
        #expect((try? decoder.decode([PreF188Meeting].self, from: data)) != nil,
                "\(name) no longer decodes in an older build")
        checked += 1
    }
    #expect(checked >= 2, "fixture: the check must have read some rewritten history (\(checked))")
    for name in ["meetings.json", "meetings.backup.json"] {
        let data = try Data(contentsOf: library.root.appendingPathComponent(name))
        #expect((try? decoder.decode([PreF188Meeting].self, from: data)) != nil,
                "\(name) no longer decodes in an older build")
    }
}
