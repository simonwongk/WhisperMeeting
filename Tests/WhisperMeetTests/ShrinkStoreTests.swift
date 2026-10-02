import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — the save Shrink commits through. Shaped like `delete(ids:)` (F451): the save is the first
// effect, and a save that fails puts the record back, so nothing on disk is ever deleted for an
// index that still names it.

private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShrinkStore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("Repointing a recording saves it, and a reopened library sees the new path (F795)")
@MainActor
func shrinkReplaceRecordingPathPersists() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Standup", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed))
    #expect(store.replaceRecordingPath(id: id, with: "Recordings/\(id)/meeting.m4a"))
    #expect(MeetingStore(rootDirectory: root).meeting(id: id)?.recordingPath == "Recordings/\(id)/meeting.m4a")
}

@Test("A repoint that loses a race keeps the old path and is not offered back (F795)")
@MainActor
func shrinkReplaceRecordingPathLostRaceRollsBack() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    MeetingStore(rootDirectory: root).upsert(
        MeetingRecord(id: id, title: "Standup", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed))
    let store = MeetingStore(rootDirectory: root)
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count })
    let existing = try rival.load()
    _ = try rival.save([MeetingRecord(id: id, title: "Renamed elsewhere",
                                      recordingPath: "Recordings/\(id)/meeting.wav", status: .completed)],
                       expecting: existing?.token)

    #expect(!store.replaceRecordingPath(id: id, with: "Recordings/\(id)/meeting.m4a"))
    #expect(store.meeting(id: id)?.recordingPath == "Recordings/\(id)/meeting.wav")
    // "Keep my change" must not be able to re-save a path whose file the shrink has removed: the
    // conflict recovery offers back this session's unsaved edits, and the repoint must not be one.
    #expect(!store.meetings.contains { $0.recordingPath.hasSuffix(".m4a") })
    #expect(!(store.conflictOffer?.delta.contains { $0.recordingPath.hasSuffix(".m4a") } ?? false))
}

@Test("A record that still names meeting.wav finds the shrunk meeting.m4a beside it (F795)")
@MainActor
func shrinkRecordingURLFallsBackToTheShrunkFile() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1]).write(to: folder.appendingPathComponent("meeting.m4a"))
    let store = MeetingStore(rootDirectory: root)
    let stale = MeetingRecord(id: id, title: "Restored", recordingPath: "Recordings/\(id)/meeting.wav", status: .completed)
    #expect(store.recordingURL(for: stale).lastPathComponent == "meeting.m4a")
    // With the WAV present, the WAV is the answer: the fallback never hides a real file.
    try Data([1]).write(to: folder.appendingPathComponent("meeting.wav"))
    #expect(store.recordingURL(for: stale).lastPathComponent == "meeting.wav")
}
