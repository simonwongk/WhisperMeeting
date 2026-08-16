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
