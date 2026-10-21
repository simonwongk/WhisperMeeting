import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F943 — F804 clears Finder's Locked flag (`uchg`) and the append-only flag (`uappnd`) on the copy an
// import makes, at import time. A meeting imported before F804 still has a locked `recording.<ext>` in
// its folder: Delete Meeting kept it ("could not have their recordings removed"), and Shrink could not
// remove its original and said so on every retry. The flags are now cleared on the files of the
// meeting's own `Recordings/<id>` folder as a delete or a Shrink removes them — the app's own files,
// which the app decides when to replace or delete — and on nothing outside that folder: another
// meeting's copy and the user's own file keep their locks. Synthetic files in temp folders only,
// unlocked again before they are cleaned up.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F943-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

/// An unlocked, real 48 kHz WAV: the copy is locked afterwards, the way an import before F804 left it.
private func makeRecording(named name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F943-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    let samples = (0..<(2 * 48_000)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
    try WAVWriter.wavData(from: samples, sampleRate: 48_000).write(to: url)
    return url
}

private func isLocked(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.immutable] as? Bool ?? false
}

private func lock(_ url: URL, appendOnly: Bool = false) throws {
    try FileManager.default.setAttributes([appendOnly ? .appendOnly : .immutable: true], ofItemAtPath: url.path)
}

/// Clears both flags on everything under `folder`, then removes it. Without the unlock a run of these
/// tests against code that keeps the flags would leave undeletable files in the temp folder.
private func unlockAndRemove(_ folder: URL) {
    let manager = FileManager.default
    if let items = manager.enumerator(atPath: folder.path) {
        for case let item as String in items {
            try? manager.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: folder.appendingPathComponent(item).path)
        }
    }
    try? manager.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: folder.path)
    try? manager.removeItem(at: folder)
}

/// Imports `source` and then locks the library's copy, as a build before F804 left it.
@MainActor
private func importWithALockedCopy(_ source: URL, into model: AppModel, appendOnly: Bool = false) async throws -> (id: UUID, copy: URL) {
    let id = try #require(await model.importRecordings(from: [source], title: "").firstID)
    let copy = model.store.recordingURL(for: try #require(model.store.meeting(id: id)))
    try lock(copy, appendOnly: appendOnly)
    return (id, copy)
}

@MainActor
@Test("A meeting whose library copy was locked before F804 can be deleted, whichever flag it carries (F943)")
func aMeetingWithALockedCopyCanBeDeleted() async throws {
    for appendOnly in [false, true] {
        let model = try makeModel()
        defer { unlockAndRemove(model.store.rootDirectory) }
        let source = try makeRecording(named: "archived call.wav")
        defer { unlockAndRemove(source.deletingLastPathComponent()) }
        let (id, _) = try await importWithALockedCopy(source, into: model, appendOnly: appendOnly)
        let folder = model.store.recordingDirectoryURL(for: id)
        try #require(FileManager.default.fileExists(atPath: folder.path))

        model.deleteMeetings(ids: [id])

        let flag = appendOnly ? "uappnd" : "uchg"
        #expect(model.store.meeting(id: id) == nil, "\(flag): \(model.store.storageErrorMessage ?? "no storage message")")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "\(flag): the folder was kept")
        #expect(model.store.storageErrorMessage == nil, "\(flag): \(model.store.storageErrorMessage ?? "")")
    }
}

@MainActor
@Test("A meeting whose library copy was locked before F804 can be shrunk, and its original is removed (F943)")
func aMeetingWithALockedCopyCanBeShrunk() async throws {
    let model = try makeModel()
    defer { unlockAndRemove(model.store.rootDirectory) }
    let source = try makeRecording(named: "archived call.wav")
    defer { unlockAndRemove(source.deletingLastPathComponent()) }
    let (id, copy) = try await importWithALockedCopy(source, into: model)
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
    #expect(!FileManager.default.fileExists(atPath: copy.path), "the locked original was kept beside the compressed copy")
}

@MainActor
@Test("A delete clears the flags of the meeting's own files only: another meeting's locked copy and the user's locked file stay locked (F943)")
func aDeleteUnlocksOnlyTheMeetingsOwnFolder() async throws {
    let model = try makeModel()
    defer { unlockAndRemove(model.store.rootDirectory) }
    let sourceA = try makeRecording(named: "call a.wav")
    defer { unlockAndRemove(sourceA.deletingLastPathComponent()) }
    let sourceB = try makeRecording(named: "call b.wav")
    defer { unlockAndRemove(sourceB.deletingLastPathComponent()) }
    let (a, _) = try await importWithALockedCopy(sourceA, into: model)
    let (b, copyB) = try await importWithALockedCopy(sourceB, into: model)
    // The user's own file, locked as they left it; an import never touches it (F804).
    try lock(sourceA)

    model.deleteMeetings(ids: [a])

    #expect(model.store.meeting(id: a) == nil, "\(model.store.storageErrorMessage ?? "")")
    #expect(model.store.meeting(id: b) != nil)
    #expect(isLocked(copyB), "another meeting's copy was unlocked")
    #expect(isLocked(sourceA), "the user's file was unlocked")
}
