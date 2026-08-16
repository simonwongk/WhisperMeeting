import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

/// A writable library holding `count` meetings, each with a real recording directory and a file in it.
@MainActor
private func makeLibrary(count: Int) throws -> (MeetingStore, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    var ids: [UUID] = []
    for index in 0..<count {
        let id = UUID()
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
        store.upsert(MeetingRecord(
            id: id,
            title: "Meeting \(index)",
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed,
            transcriptText: "transcript \(index)"
        ))
        ids.append(id)
    }
    return (store, root, ids)
}

@Test("Deleting several meetings writes the index once, not once per meeting")
@MainActor
func batchDeleteWritesTheIndexOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.delete(ids: ids)

    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == before + 1)
    for id in ids {
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Test("A meeting whose directory cannot be removed is kept, and the rest still delete")
@MainActor
func batchDeleteKeepsWhatItCouldNotRemove() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let stubborn = ids[1]
    store.removeRecordingDirectory = { url in
        if url.lastPathComponent == stubborn.uuidString {
            throw NSError(domain: "test", code: 1)
        }
        try FileManager.default.removeItem(at: url)
    }

    store.delete(ids: ids)

    #expect(store.meetings.map(\.id) == [stubborn])
    #expect(store.storageErrorMessage != nil)
}

@Test("Batch delete is refused while the library is read-only, and removes no audio")
@MainActor
func batchDeleteRefusedWhileDegraded() throws {
    // Seed a writable library, then corrupt only the primary index so the backup loads:
    // that yields `.recoveredFromBackup`, which is degraded AND still has records and audio.
    let (_, root, ids) = try makeLibrary(count: 2)
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    // `BackupJSONStore.save()` writes the PREVIOUS primary into the backup, so after two upserts the
    // backup is one generation behind and holds only one meeting. Copy the primary across first, or
    // this fixture silently tests a one-record library and the count assertion below is meaningless.
    try? FileManager.default.removeItem(at: backup)
    try FileManager.default.copyItem(at: primary, to: backup)
    try Data("broken-primary".utf8).write(to: primary)

    let store = MeetingStore(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(store.meetings.count == 2)
    let before = store.persistCount
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(ids: ids)

    #expect(!removalAttempted)
    #expect(store.meetings.count == 2)
    #expect(store.persistCount == before)
    for id in ids {
        let wav = root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }
    #expect(store.storageErrorMessage != nil)
}

@Test("Adding a tag to several meetings writes the index once and applies to all")
@MainActor
func batchAddTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.setTags(id: ids[0], ["existing"])
    let before = store.persistCount

    store.addTag("  Budget  ", to: ids)

    #expect(store.persistCount == before + 1)
    for id in ids {
        let tags = store.meeting(id: id)?.tags ?? []
        #expect(tags.contains("Budget"))          // trimmed by MeetingTags.normalized
    }
    #expect(store.meeting(id: ids[0])?.tags?.contains("existing") == true)
}

@Test("Removing a tag takes it off every selected meeting and leaves others alone")
@MainActor
func batchRemoveTagWritesOnce() throws {
    let (store, root, ids) = try makeLibrary(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    store.addTag("shared", to: ids)
    store.setTags(id: ids[2], ["shared", "keep"])
    let before = store.persistCount

    store.removeTag("shared", from: [ids[0], ids[2]])

    #expect(store.persistCount == before + 1)
    #expect(store.meeting(id: ids[0])?.tags?.contains("shared") != true)
    #expect(store.meeting(id: ids[1])?.tags?.contains("shared") == true)
    #expect(store.meeting(id: ids[2])?.tags == ["keep"])
}
