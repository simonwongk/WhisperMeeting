import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F804 — a file locked in Finder (the user-immutable flag, `uchg`) was imported with
// `FileManager.copyItem`, which keeps that flag on the copy. `removeItem` then fails on the library's
// own copy with a permission error: Delete Meeting kept the meeting as "could not have its recording
// removed", and Shrink reported a file it could not remove on every retry. The library's copy is the
// app's file, so the app clears the flag on it; the user's file keeps its lock. Synthetic files in
// temp folders only, unlocked again before they are cleaned up.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LockedImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// A locked, real 48 kHz WAV, the way a user's archived recording can be. 48 kHz because Shrink's
/// real encoder is used below, and a capture-shaped file is what it is written for.
private func makeLockedRecording() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LockedImportFiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("archived call.wav")
    let samples = (0..<(2 * 48_000)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
    try WAVWriter.wavData(from: samples, sampleRate: 48_000).write(to: url)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    return url
}

private func isLocked(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.immutable] as? Bool ?? false
}

/// Clears the lock on everything under `folder`, then removes it. Without the unlock a run of these
/// tests against code that keeps the flag would leave undeletable files in the temp folder.
private func unlockAndRemove(_ folder: URL) {
    let manager = FileManager.default
    if let items = manager.enumerator(atPath: folder.path) {
        for case let item as String in items {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: folder.appendingPathComponent(item).path)
        }
    }
    try? manager.setAttributes([.immutable: false], ofItemAtPath: folder.path)
    try? manager.removeItem(at: folder)
}

@MainActor
@Test("A locked file is imported as an unlocked library copy, and the user's file keeps its lock (F804)")
func lockedFileImportsAsAnUnlockedCopy() async throws {
    let model = try makeModel()
    defer { unlockAndRemove(model.store.rootDirectory) }
    let source = try makeLockedRecording()
    defer { unlockAndRemove(source.deletingLastPathComponent()) }
    let sourceBytes = try Data(contentsOf: source)

    let id = try #require(await model.importRecordings(from: [source], title: "").firstID)

    let meeting = try #require(model.store.meeting(id: id))
    let copy = model.store.recordingURL(for: meeting)
    #expect(!isLocked(copy), "the library's copy is the app's own file")
    #expect(try Data(contentsOf: copy) == sourceBytes)
    #expect(isLocked(source), "the user's file is never modified")
}

@MainActor
@Test("A meeting imported from a locked file can be deleted (F804)")
func meetingImportedFromALockedFileCanBeDeleted() async throws {
    let model = try makeModel()
    defer { unlockAndRemove(model.store.rootDirectory) }
    let source = try makeLockedRecording()
    defer { unlockAndRemove(source.deletingLastPathComponent()) }
    let id = try #require(await model.importRecordings(from: [source], title: "").firstID)
    let folder = model.store.recordingDirectoryURL(for: id)
    try #require(FileManager.default.fileExists(atPath: folder.path))

    model.deleteMeetings(ids: [id])

    #expect(model.store.meeting(id: id) == nil, "\(model.store.storageErrorMessage ?? "no storage message")")
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(model.store.storageErrorMessage == nil)
    #expect(isLocked(source))
}

@MainActor
@Test("A meeting imported from a locked file can be shrunk, and its original is removed (F804)")
func meetingImportedFromALockedFileCanBeShrunk() async throws {
    let model = try makeModel()
    defer { unlockAndRemove(model.store.rootDirectory) }
    let source = try makeLockedRecording()
    defer { unlockAndRemove(source.deletingLastPathComponent()) }
    let id = try #require(await model.importRecordings(from: [source], title: "").firstID)
    let folder = model.store.recordingDirectoryURL(for: id)
    // The free-space figure is the host's; this test is about removal, not space.
    model.availableBytesForShrink = { _ in .max }

    await model.refreshStorage(ids: [id])
    try #require(model.shrinkUnavailability(for: try #require(model.store.meeting(id: id))) == nil)
    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let alert = model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(!alert.contains("could not be removed"), "\(alert)")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.wav").path),
            "the import's original copy is removed once the compressed one is saved")
    #expect(isLocked(source))
}
