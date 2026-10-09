import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F526 — the meeting index is encoded one record at a time, on every core, and spliced into the
/// array. That is a speed change and nothing else: the bytes on disk must be exactly the ones the
/// whole-array encoder writes, or every build reading the file — this one, older ones, a person in
/// a text editor following docs/RECOVERY.md — would be reading a different format.
@MainActor
@Test("The meeting index on disk is exactly the whole-array encoding of the library (F526)")
func theMeetingIndexOnDiskIsTheWholeArrayEncoding() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F526Fidelity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    let titles = ["Standup", "", "Line one\nline two", "Quote \" and \\ slash /", "中文会议 🎙️", "e\u{301}"]
    for index in 0..<24 {
        var record = index.isMultiple(of: 3)
            ? MeetingRecord(title: titles[index % titles.count])
            : PersistedRootDerivedDecodeTests.fullyPopulatedMeeting()
        record.title = titles[index % titles.count]
        record.notes = index.isMultiple(of: 4) ? nil : "agenda\t— \(index)\r\n"
        record.tags = index.isMultiple(of: 5) ? [] : record.tags
        store.upsert(record, as: .result)
    }
    #expect(store.persistCommitCount == 24)

    let onDisk = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    let whole = try BackupJSONStore<[MeetingRecord]>.makeEncoder().encode(store.meetings)
    #expect(onDisk == whole)
}

/// The meeting store's opt-in is the whole of the speed-up's reachability, and nothing above can see
/// it: the bytes are the same either way, which is the point, and the core tests drive
/// `BackupJSONStore` directly (the lane-V review's V6 — a mutant turning it off passed every test).
/// Read off a real store rather than out of the source text, so it is the value the app runs with.
@MainActor
@Test("The meeting store encodes its index element by element (F526)")
func theMeetingStoreEncodesItsIndexElementByElement() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F526OptIn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    let meetingFiles = try #require(
        Mirror(reflecting: store).children.first { $0.label == "meetingFiles" }?.value,
        "MeetingStore has no stored `meetingFiles`; this test reads the opt-in from it"
    )
    let optedIn = try #require(
        Mirror(reflecting: meetingFiles).children.first { $0.label == "encodesElementsConcurrently" }?.value as? Bool,
        "the meeting index's store has no `encodesElementsConcurrently` flag"
    )
    #expect(optedIn, "the meeting index is encoded with one encoder again: ~2 s per edit at 1,000 meetings")
}
