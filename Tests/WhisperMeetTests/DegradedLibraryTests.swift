import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeDegradedStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetDegraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    return (MeetingStore(rootDirectory: root), root)
}

@Test("An unreadable index leaves the store degraded rather than empty-and-writable")
@MainActor
func unreadableIndexIsDegraded() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(!store.health.allowsMutation)
}

@Test("Deleting while degraded removes no audio and no record")
@MainActor
func degradedDeleteRemovesNothing() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(id: id)

    #expect(!removalAttempted)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    #expect(store.storageErrorMessage != nil)
}

@Test("No mutation while degraded reaches disk or memory")
@MainActor
func degradedMutationsAreRefused() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.upsert(MeetingRecord(title: "New"))
    store.setTags(id: UUID(), ["x"])
    store.addVocabulary(["term"])

    #expect(store.meetings.isEmpty)
    #expect(store.vocabulary.isEmpty)
    #expect(store.persistCount == before)
}

@Test("A degraded index reports no orphans, so startup cannot rebuild over it")
@MainActor
func degradedIndexReportsNoOrphans() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(try store.orphanedRecordings().isEmpty)
}
