import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F494 — importing a symbolic link copies the recording it points to. `copyItem` copies a link as
// the link itself, so the library held a pointer to the user's file: unplayable once they deleted
// the original or ejected the drive it was on, and skipped by backups, which take regular files only.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SymlinkImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SymlinkImportFiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A real, parseable WAV: the import measures its duration before adopting it (F326).
private func writeRecording(to url: URL) throws {
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
}

/// What the item at `path` is — not what it points to: `attributesOfItem` does not follow a link.
private func itemType(atPath path: String) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
}

@MainActor
private func libraryRecordingFolders(of model: AppModel) -> [String] {
    let recordings = model.store.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
}

@MainActor
@Test("Importing a link copies the recording it points to, and the copy outlives the original (F494)")
func linkedRecordingIsCopiedNotLinked() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let originals = try makeFolder()
    defer { try? FileManager.default.removeItem(at: originals) }
    let links = try makeFolder()
    defer { try? FileManager.default.removeItem(at: links) }
    let original = originals.appendingPathComponent("take-3.wav")
    try writeRecording(to: original)
    let link = links.appendingPathComponent("interview.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    let originalBytes = try Data(contentsOf: original)

    let imported = await model.importRecording(from: link, title: "")

    let id = try #require(imported)
    let meeting = try #require(model.store.meeting(id: id))
    let copy = model.store.recordingURL(for: meeting)
    #expect(itemType(atPath: copy.path) == .typeRegular, "a link in the library points outside it")
    #expect(meeting.title == "interview", "named after what the user chose, not what it points to")
    // The user deletes the original, believing the library has its own copy — which it now does.
    try FileManager.default.removeItem(at: original)
    #expect((try? Data(contentsOf: copy)) == originalBytes)
}

@MainActor
@Test("A relative link is copied as its recording, not as a link that dangles inside the library (F494)")
func relativeLinkIsCopiedAsItsRecording() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try writeRecording(to: folder.appendingPathComponent("real.wav"))
    let link = folder.appendingPathComponent("talk.wav")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.wav")

    let imported = await model.importRecording(from: link, title: "")

    let id = try #require(imported)
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.duration > 0, "`talk.wav -> real.wav` copied into another folder points at nothing")
    #expect(itemType(atPath: model.store.recordingURL(for: meeting).path) == .typeRegular)
}

@MainActor
@Test("A link whose original cannot be found is refused and says so, instead of becoming an empty meeting (F494)")
func danglingLinkIsRefused() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The original is on a card that has been ejected.
    let link = folder.appendingPathComponent("talk.wav")
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: "/Volumes/F494-ejected-\(UUID().uuidString)/talk.wav"
    )

    let imported = await model.importRecording(from: link, title: "")

    #expect(imported == nil)
    #expect(model.store.meetings.isEmpty)
    #expect(libraryRecordingFolders(of: model).isEmpty)
    #expect(model.alertMessage?.contains("link to a file that cannot be found") == true)
    #expect(!model.isImporting)
}

@MainActor
@Test("The free-space check measures the recording a link points to, not the link (F494)")
func freeSpaceCheckMeasuresTheLinkedRecording() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Sparse, so it occupies nothing: 1 PiB is more than any Mac has free, and a link to it is a
    // hundred-odd bytes. The copy seam stands in for the copy, so no state of this test copies it.
    let huge = folder.appendingPathComponent("huge.wav")
    #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: 1 << 50)
    try handle.close()
    let link = folder.appendingPathComponent("talk.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: huge)
    let copyAttempts = CopyAttempts()
    model.copyRecordingIntoLibrary = { _, _ in
        copyAttempts.record()
        throw CocoaError(.fileWriteOutOfSpace)
    }
    // The check is skipped when the volume reports no free-space figure, so require that it does:
    // otherwise this test would fail as a claim about links when it is a fact about the host.
    model.refreshRecordingPreflight()
    try #require(model.recordingPreflight.availableStorageBytes != nil)

    let imported = await model.importRecording(from: link, title: "")

    #expect(imported == nil)
    #expect(copyAttempts.count == 0, "refused before copying, the way a 1 PiB file itself is")
    #expect(model.alertMessage?.contains("free") == true)
    #expect(libraryRecordingFolders(of: model).isEmpty)
}

@MainActor
@Test("A link whose recording grows while it is copied is refused: the re-check watches the recording, not the link (F494)")
func linkedRecordingGrowingDuringTheCopyIsRefused() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("real.wav")
    try writeRecording(to: original)
    let link = folder.appendingPathComponent("talk.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    // The writer resumes during the copy. It writes to the recording, never to the link, whose own
    // size and date stay what they were.
    model.copyRecordingIntoLibrary = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
        let handle = try FileHandle(forWritingTo: original)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 4_096))
    }

    let imported = await model.importRecording(from: link, title: "")

    #expect(imported == nil, "the library's copy is a prefix of what the link points to now")
    #expect(model.store.meetings.isEmpty)
    #expect(libraryRecordingFolders(of: model).isEmpty)
    #expect(model.alertMessage?.contains("still being written") == true)
}

/// Counts calls into the copy seam, which runs on the import's detached task.
private final class CopyAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}
