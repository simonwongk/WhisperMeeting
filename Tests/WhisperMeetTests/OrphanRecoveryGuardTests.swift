import Foundation
import Testing
@testable import WhisperMeet

// F148 #1 — a recording folder whose id already belongs to a meeting must NOT be treated as an orphan,
// even if that meeting's recordingPath is wrong. Otherwise startup "recovery" upserts a blank stub under
// the same id and overwrites the saved title/transcript/notes/tags/summary.
@MainActor
@Test("orphanedRecordings ignores a folder whose id already has a meeting (F148 #1)")
func orphanRecoveryDoesNotClaimExistingMeetingFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanGuard-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    // The meeting exists (with real content) but its recordingPath is WRONG — it doesn't point at its
    // own folder, so the folder isn't in the path-derived indexed set.
    store.upsert(MeetingRecord(
        id: id, title: "Important Meeting",
        recordingPath: "Recordings/\(UUID().uuidString)/meeting.wav", // wrong folder
        status: .completed, transcriptText: "precious transcript",
        notes: "my notes", tags: ["budget"]
    ))

    let orphans = try store.orphanedRecordings()
    #expect(!orphans.contains { $0.id == id }) // not treated as orphan → recovery won't clobber it
}
