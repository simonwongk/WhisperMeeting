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
