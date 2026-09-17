import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F187 — `BackupJSONStore` grew element-wise salvage so that one bad record costs one record rather
// than the whole library. The meeting index — the one index that actually got wiped on 2026-08-14 —
// was constructed WITHOUT a `salvage:` closure, so `.partiallySalvaged` was unreachable for it and
// `loadMeetings()`'s handler for that case was dead code. These tests drive salvage through the real
// `MeetingStore(rootDirectory:)` load path, not through a hand-built `BackupJSONStore`.
//
// They live in their own file rather than in `DegradedLibraryTests.swift` because every helper there
// builds an index that is beyond rescue, in order to prove what a read-only library REFUSES. This file
// needs the opposite fixture — an index that is mostly good — and asserts what the load path RECOVERS.

/// Encodes real `MeetingRecord`s exactly as `BackupJSONStore` persists them (`.iso8601` dates), then
/// hands the array back as mutable dictionaries so a test can damage one element.
///
/// Built from encoded values rather than hand-written JSON on purpose: a literal drifts from the real
/// `MeetingRecord` schema the moment a field is added, and would leave a test that passes because
/// EVERY element failed to decode rather than because the intended one did (F187).
private func encodedElements(_ records: [MeetingRecord]) throws -> [[String: Any]] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try JSONSerialization.jsonObject(with: try encoder.encode(records))
    return try #require(object as? [[String: Any]])
}

/// Writes `bytes` as BOTH `meetings.json` and `meetings.backup.json` in a fresh temp library, so the
/// backup path cannot rescue the file whole and salvage is the only thing that can save anything.
@MainActor
private func makeStore(indexBytes bytes: Data) throws -> (store: MeetingStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetSalvage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try bytes.write(to: root.appendingPathComponent("meetings.json"))
    try bytes.write(to: root.appendingPathComponent("meetings.backup.json"))
    return (MeetingStore(rootDirectory: root), root)
}

@MainActor
private func makeStore(index elements: [Any]) throws -> (store: MeetingStore, root: URL) {
    try makeStore(indexBytes: try JSONSerialization.data(withJSONObject: elements))
}

/// The copy-aside files `StoreQuarantine` leaves next to the index (`<stem>.unreadable-<stamp>.json`).
private func quarantinedNames(in root: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { $0.contains(".unreadable-") }
}

// The headline case, and the exact shape of the 2026-08-14 failure: an index that is fine apart from
// one record. Before this task the whole file was declared unreadable and the library opened empty.
@Test("An index with one undecodable record loads the rest and names what was parked")
@MainActor
func partlyUndecodableIndexKeepsItsReadableRecords() throws {
    let alpha = MeetingRecord(title: "Alpha")
    let bravo = MeetingRecord(title: "Bravo")
    let charlie = MeetingRecord(title: "Charlie")
    var elements = try encodedElements([alpha, bravo, charlie])
    elements[1].removeValue(forKey: "title") // `title` is non-optional, so ONLY this element fails

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.count == 2)
    #expect(Set(store.meetings.map(\.id)) == [alpha.id, charlie.id])
    #expect(store.meetings.contains { $0.title == "Alpha" })
    // Updated by F197: this expected the bare `bravo.id.uuidString`. The fixture removes `title`
    // (the only way to fail exactly one element), so the record has an id and no title, and the name
    // is now a description plus the short id rather than a raw UUID standing alone.
    #expect(store.health == .partiallySalvaged(
        parkedIdentifiers: ["untitled meeting (\(bravo.id.uuidString.prefix(8)))"]
    ))
    // Salvage improves what the user can SEE, not what they can change: `.partiallySalvaged` does not
    // allow mutation, so a salvaged library is still open read-only.
    #expect(store.isDegraded)

    let message = try #require(store.startupRecoveryMessages.first { $0.contains("could not be read") })
    #expect(message.contains("1 meeting record"))
    // The original bytes survive: salvage runs from the preserved copies, never instead of preserving.
    #expect(quarantinedNames(in: root).count == 2)
}

@Test("A parked record is named by its title, with a short id to grep for (F197)")
@MainActor
func parkedIdentifiersPreferTitleForDisplay() throws {
    // This test previously pinned id-FIRST, and F197 is the correction. A bare UUID tells the user
    // nothing they can act on: they are being asked to look for a meeting inside a quarantined JSON
    // file, and what they remember is "Budget review", not `6F1A0000-…`. The short id stays
    // alongside it, because that is the string they would actually grep for once they open the file
    // — dropping it would trade one unusable name for another.
    let alpha = MeetingRecord(title: "Alpha")
    let bravo = MeetingRecord(title: "Bravo")
    var elements = try encodedElements([
        alpha, bravo, MeetingRecord(title: "Charlie"), MeetingRecord(title: "Delta")
    ])
    elements[1].removeValue(forKey: "duration") // title AND id survive -> both shown
    elements[2].removeValue(forKey: "id")       // no id -> title alone
    elements[3].removeValue(forKey: "id")
    elements[3].removeValue(forKey: "title")    // neither -> position

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.map(\.id) == [alpha.id])
    let shortBravo = String(bravo.id.uuidString.prefix(8))
    #expect(store.health == .partiallySalvaged(
        parkedIdentifiers: ["Bravo (\(shortBravo))", "Charlie", "record at index 3"]
    ))
}

@Test("An untitled parked record is described, not left as a bare UUID (F197)")
@MainActor
func untitledParkedRecordIsDescribed() throws {
    let alpha = MeetingRecord(title: "Alpha")
    let bravo = MeetingRecord(title: "")
    var elements = try encodedElements([alpha, bravo])
    elements[1].removeValue(forKey: "duration")

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    let shortBravo = String(bravo.id.uuidString.prefix(8))
    #expect(store.health == .partiallySalvaged(
        parkedIdentifiers: ["untitled meeting (\(shortBravo))"]
    ))
}

@Test("The startup message names the parked meetings, not just how many (F197)")
@MainActor
func startupMessageNamesTheParkedRecords() throws {
    // The store knew which records it parked and told the user only a count — "N meeting record(s)
    // could not be read" — so they were informed that something was missing and given no way to
    // tell what. Since salvage became reachable for the meeting index, that sentence is the only
    // thing they see.
    let alpha = MeetingRecord(title: "Alpha")
    var elements = try encodedElements([
        alpha, MeetingRecord(title: "Budget review"), MeetingRecord(title: "Hiring sync")
    ])
    elements[1].removeValue(forKey: "duration")
    elements[2].removeValue(forKey: "duration")

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    let message = try #require(
        store.startupRecoveryMessages.first { $0.contains("could not be read") }
    )
    #expect(message.contains("2 meeting records"))
    #expect(message.contains("Budget review"))
    #expect(message.contains("Hiring sync"))
    #expect(message.contains("preserved copy"))
}

@Test("A long list of parked records is summarised rather than printed whole (F197)")
@MainActor
func manyParkedRecordsAreSummarised() throws {
    // A wholly-corrupt index can park hundreds. Naming every one turns an actionable message into a
    // wall of text, so the message names a handful and counts the rest — the names exist to help a
    // user recognise what to look for, and past a few they stop doing that.
    let good = MeetingRecord(title: "Good")
    var records = [good]
    for index in 0..<12 { records.append(MeetingRecord(title: "Meeting \(index)")) }
    var elements = try encodedElements(records)
    for index in 1...12 { elements[index].removeValue(forKey: "duration") }

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    let message = try #require(
        store.startupRecoveryMessages.first { $0.contains("could not be read") }
    )
    #expect(message.contains("12 meeting records"))
    #expect(message.contains("Meeting 0"))
    #expect(message.contains("and 7 more"), "expected the tail to be counted, not listed")
    #expect(!message.contains("Meeting 11"))
}

// An element that is not even a JSON object must be parked, not crash the salvage. A bare number
// cannot be re-serialized as a top-level JSON fragment, which is why the implementation decodes each
// element wrapped back into a one-element array (F187).
@Test("A non-object element is parked by position rather than crashing the salvage")
@MainActor
func nonObjectElementIsParkedByPosition() throws {
    let alpha = MeetingRecord(title: "Alpha")
    var elements: [Any] = try encodedElements([alpha])
    elements.append(42)
    elements.append("not a record")

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.map(\.id) == [alpha.id])
    #expect(store.health == .partiallySalvaged(
        parkedIdentifiers: ["record at index 1", "record at index 2"]
    ))
}

// `.partiallySalvaged(parkedIdentifiers: [...])` next to an EMPTY library would read to the user as
// "your meetings are gone" while claiming a partial rescue. The honest answer when nothing decoded is
// that neither copy could be read, with the quarantine files named — so salvage returns nil and the
// real error stands (F187).
@Test("An index where no record survives reports no readable copy, not an empty salvage")
@MainActor
func indexWithNoSurvivingRecordStaysUnreadable() throws {
    var elements = try encodedElements([MeetingRecord(title: "Alpha"), MeetingRecord(title: "Bravo")])
    for index in elements.indices { elements[index].removeValue(forKey: "title") }

    let (store, root) = try makeStore(index: elements)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.isEmpty)
    guard case let .unreadable(quarantined) = store.health else {
        Issue.record("expected .unreadable, got \(store.health)")
        return
    }
    #expect(quarantined.count == 2)
    #expect(store.isDegraded)
}

// Bytes that are not a JSON array at all have nothing element-wise to rescue. This is the shape
// `DegradedLibraryTests.makeDegradedStore()` writes, and a great many tests depend on that helper
// still producing `.unreadable` — so pin it here rather than assume it.
@Test("An index that is not a JSON array is still unreadable, never salvaged")
@MainActor
func nonArrayIndexIsNeverSalvaged() throws {
    let (store, root) = try makeStore(indexBytes: Data("broken-primary".utf8))
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.isEmpty)
    guard case .unreadable = store.health else {
        Issue.record("expected .unreadable, got \(store.health)")
        return
    }
}

// A JSON object (rather than an array) is valid JSON, so it gets past `JSONSerialization` and would
// reach the element loop if the top-level shape were not checked.
@Test("An index whose top level is a JSON object is unreadable, never salvaged")
@MainActor
func objectTopLevelIndexIsNeverSalvaged() throws {
    let bytes = try JSONSerialization.data(withJSONObject: ["meetings": []] as [String: Any])
    let (store, root) = try makeStore(indexBytes: bytes)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.meetings.isEmpty)
    guard case .unreadable = store.health else {
        Issue.record("expected .unreadable, got \(store.health)")
        return
    }
}
