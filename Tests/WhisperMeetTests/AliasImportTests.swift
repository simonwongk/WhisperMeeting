import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F705 — a Finder alias named `talk.wav` passes intake on its name (`ExternalFileIntake` reads only
// the name) and is a regular file, so F494's symbolic-link resolution never saw it: `copyItem`
// copied the alias's bookmark bytes, and the library held a ~1 KB "recording" with no audio in it.
// Driven through `importRecordings(from:title:)`, the call the Import panel and Finder/Dock/Services
// make. Every file here is synthetic and lives in a temp folder.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AliasImport-\(UUID().uuidString)", isDirectory: true)
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
        .appendingPathComponent("AliasImportFiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A real, parseable WAV: the import measures its duration before adopting it (F326).
private func writeRecording(to url: URL) throws {
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
}

/// A Finder alias at `alias` pointing at `target`, written the way Finder writes one.
private func makeAlias(at alias: URL, to target: URL) throws {
    let bookmark = try target.bookmarkData(
        options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil
    )
    try URL.writeBookmarkData(bookmark, to: alias)
}

@MainActor
private func libraryRecordingFolders(of model: AppModel) -> [String] {
    let recordings = model.store.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
}

@MainActor
@Test("Importing a Finder alias copies the recording it points to, not the alias's bytes (F705)")
func aliasIsImportedAsItsRecording() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let originals = try makeFolder()
    defer { try? FileManager.default.removeItem(at: originals) }
    let aliases = try makeFolder()
    defer { try? FileManager.default.removeItem(at: aliases) }
    let original = originals.appendingPathComponent("take-3.wav")
    try writeRecording(to: original)
    let alias = aliases.appendingPathComponent("talk.wav")
    try makeAlias(at: alias, to: original)
    // The premise: an alias is a regular file, so nothing that resolves symbolic links touches it.
    let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isRegularFileKey, .isSymbolicLinkKey])
    try #require(values.isAliasFile == true && values.isRegularFile == true && values.isSymbolicLink == false)
    let originalBytes = try Data(contentsOf: original)

    let imported = await model.importRecordings(from: [alias], title: "").firstID

    let id = try #require(imported)
    let meeting = try #require(model.store.meeting(id: id))
    let copy = model.store.recordingURL(for: meeting)
    #expect(meeting.duration > 0, "the alias's bookmark bytes are not audio")
    #expect((try? Data(contentsOf: copy)) == originalBytes)
    #expect((try? copy.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == false)
    #expect(meeting.title == "talk", "named after what the user chose, not what it points to")
    // The user deletes the original, believing the library has its own copy — which it now does.
    try FileManager.default.removeItem(at: original)
    #expect((try? Data(contentsOf: copy)) == originalBytes)
}

@MainActor
@Test("An alias whose original cannot be found is refused and says so, instead of becoming an empty meeting (F705)")
func aliasToMissingRecordingIsRefused() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("take-3.wav")
    try writeRecording(to: original)
    let alias = folder.appendingPathComponent("talk.wav")
    try makeAlias(at: alias, to: original)
    try FileManager.default.removeItem(at: original)

    let outcome = await model.importRecordings(from: [alias], title: "")

    #expect(outcome.firstID == nil)
    #expect(model.store.meetings.isEmpty)
    #expect(libraryRecordingFolders(of: model).isEmpty)
    #expect(model.alertMessage?.contains("cannot be found") == true, "\(model.alertMessage ?? "nil")")
    #expect(!model.isImporting)
}

@MainActor
@Test("An alias to a folder is refused, not copied as a meeting (F705)")
func aliasToFolderIsRefused() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("Interviews", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try writeRecording(to: target.appendingPathComponent("inside.wav"))
    let alias = folder.appendingPathComponent("interviews.m4a")
    try makeAlias(at: alias, to: target)

    let outcome = await model.importRecordings(from: [alias], title: "")

    #expect(outcome.firstID == nil)
    #expect(model.store.meetings.isEmpty)
    #expect(libraryRecordingFolders(of: model).isEmpty)
    #expect(model.alertMessage?.contains("folder") == true, "\(model.alertMessage ?? "nil")")
}

@MainActor
@Test("The free-space check measures the recording an alias points to, not the alias (F705)")
func freeSpaceCheckMeasuresTheAliasedRecording() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Sparse, so it occupies nothing: 1 PiB is more than any Mac has free, and an alias to it is
    // about a kilobyte. The copy seam stands in for the copy, so no state of this test copies it.
    let huge = folder.appendingPathComponent("huge.wav")
    #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: 1 << 50)
    try handle.close()
    let alias = folder.appendingPathComponent("talk.wav")
    try makeAlias(at: alias, to: huge)
    let copyAttempts = CopyAttempts()
    model.copyRecordingIntoLibrary = { _, _ in
        copyAttempts.record()
        throw CocoaError(.fileWriteOutOfSpace)
    }
    // The check is skipped when the volume reports no free-space figure, so require that it does:
    // otherwise this test would fail as a claim about aliases when it is a fact about the host.
    model.refreshRecordingPreflight()
    try #require(model.recordingPreflight.availableStorageBytes != nil)

    let outcome = await model.importRecordings(from: [alias], title: "")

    #expect(outcome.firstID == nil)
    #expect(copyAttempts.count == 0, "refused before copying, the way a 1 PiB file itself is")
    #expect(model.alertMessage?.contains("free") == true, "\(model.alertMessage ?? "nil")")
    #expect(libraryRecordingFolders(of: model).isEmpty)
}

/// Counts calls into the copy seam, which runs on the import's detached task.
private final class CopyAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}
