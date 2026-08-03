import Foundation
import Testing
@testable import WhisperMeet

// F146 — deleting a meeting must not silently orphan its audio: if the recording folder can't be
// removed, keep the meeting in the index and surface the error instead of half-deleting.
@MainActor
@Test("Delete keeps the meeting and reports the error when the recording can't be removed (F146)")
func deleteSurfacesRemovalFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteFail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))

    struct RemovalError: Error {}
    store.removeRecordingDirectory = { _ in throw RemovalError() }

    store.delete(id: id)

    #expect(store.meeting(id: id) != nil)                 // not half-deleted
    #expect(store.storageErrorMessage != nil)             // failure surfaced
}

@MainActor
@Test("Delete removes the meeting on successful recording removal (F146)")
func deleteSucceedsNormally() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteOK-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: dir.appendingPathComponent("meeting.wav"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))

    store.delete(id: id)

    #expect(store.meeting(id: id) == nil)                                       // removed from index
    #expect(!FileManager.default.fileExists(atPath: dir.path))                  // audio removed
}

// F148 #6 — a corrupt/tampered recordingPath with `../` must never delete files outside the library.
@MainActor
@Test("Delete never removes a directory outside the library on a traversal path (F148 #6)")
func deleteRefusesPathTraversal() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteTraversal-\(UUID().uuidString)")
    let root = tmp.appendingPathComponent("library")
    let victim = tmp.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("precious".utf8).write(to: victim.appendingPathComponent("file.txt"))
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    // recordingPath escapes the library up to ../victim/meeting.wav.
    store.upsert(MeetingRecord(id: id, title: "Evil", recordingPath: "../victim/meeting.wav", status: .completed))

    store.delete(id: id)

    #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("file.txt").path)) // untouched
    #expect(store.meeting(id: id) == nil)                                                            // entry removed
    #expect(store.storageErrorMessage != nil)                                                        // explained
}

// F148 #6 — an empty recordingPath (resolves to the library root's parent) must not delete anything.
@MainActor
@Test("Delete never removes the library root on an empty recordingPath (F148 #6)")
func deleteRefusesRootPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteRoot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("index".utf8).write(to: root.appendingPathComponent("marker.txt"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "NoPath", recordingPath: "", status: .recorded))

    store.delete(id: id)

    #expect(FileManager.default.fileExists(atPath: root.path))                               // library intact
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker.txt").path))
    #expect(store.meeting(id: id) == nil)
}
