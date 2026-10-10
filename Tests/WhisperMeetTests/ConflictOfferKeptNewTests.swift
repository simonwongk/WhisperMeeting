import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F887 (2) — a banner's "stays in your list" can name a meeting the other copy has since deleted.
//
// F667 put a meeting only this window had back in the list and saved it, and named it in the banner
// ("“Recorded here”, new in this window, stays in your list whichever you choose") or, with nothing left
// to ask, in the alert ("“Recorded here” is in your list again."). A later race folds the banner into a
// new one, and the names were carried over as they were, never checked against the newest re-read — so
// after the other copy deleted that meeting, the banner still said it stays in the list. Suspected by the
// round-2 review of Wave 4 lane Q; this is its four-event sequence.

@MainActor
private func libraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F887-kept-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

@MainActor
@Test("A meeting the banner says stays in the list is not named once the other copy has deleted it (F887)")
func aKeptMeetingTheOtherCopyDeletedIsNotNamedAgain() throws {
    let root = try libraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let standup = UUID(), review = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", status: .processing))

    // 1. The other copy renames the Standup, and this window's rename of it loses: the banner is up.
    try otherCopyCommits(in: root) { $0.map { var r = $0; if r.id == standup { r.title = "Standup, renamed there" }; return r } }
    store.update(id: standup) { $0.title = "Standup, renamed here" }
    try #require(store.conflictOffer != nil, "fixture: the rename lost and was offered back")

    // 2. The other copy saves again, and a recording stops here: its save loses, so it is put back in the
    //    list and saved, and the banner says it stays.
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's meeting", status: .recorded)] }
    let recorded = MeetingRecord(title: "Recorded here", status: .recorded)
    store.upsert(recorded, as: .result)
    let before = try #require(store.conflictOffer)
    try #require(before.message.contains("“Recorded here”, new in this window, stays in your list"), "fixture: \(before.message)")

    // 3. The other copy deletes that recording.
    try otherCopyCommits(in: root) { $0.filter { $0.id != recorded.id } }

    // 4. A transcript finishes here: its save loses, and the banner is folded into a new one.
    store.update(id: review, as: .result) { $0.transcriptText = "Ship it."; $0.status = .completed }

    #expect(store.meeting(id: recorded.id) == nil, "the other copy's delete was undone")
    let after = try #require(store.conflictOffer, "the person's rename is still a question")
    #expect(!after.message.contains("“Recorded here”"), "the banner names a meeting the other copy deleted: \(after.message)")
    #expect(after.message.contains("“Standup, renamed here”"), "\(after.message)")
}
