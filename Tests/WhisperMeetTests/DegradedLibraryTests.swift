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

// A recording started while the library is read-only produces audio the store then refuses to index,
// so the meeting vanishes with no error shown — and `orphanedRecordings()` hides it too (F187).
@Test("Recording is refused while degraded, before any folder or state changes")
@MainActor
func degradedLibraryRefusesRecording() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F187.\(UUID().uuidString)")!
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.startRecording()

    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: recordings.path))
    #expect(model.recordingState == .idle)
    let message = try #require(model.alertMessage)
    #expect(message.contains("read-only"))
    #expect(message.contains("recovery"))
}

// Defense in depth: even if a future caller skips the AppModel guard, the store itself never lays down
// a recording folder it could not index (F187).
@Test("recordingDirectory(for:) throws while degraded and creates nothing")
@MainActor
func degradedRecordingDirectoryThrows() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()

    #expect(throws: MeetingStoreError.libraryIsReadOnly) {
        try store.recordingDirectory(for: id)
    }
    #expect(!FileManager.default.fileExists(atPath: store.recordingDirectoryURL(for: id).path))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Recordings", isDirectory: true).path
    ))
}
