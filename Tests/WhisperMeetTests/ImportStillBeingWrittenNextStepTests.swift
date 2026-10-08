import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F551 — a file that changed while it was being copied is refused (F326/F698), and the refusal used
// to promise "It will be imported once it is finished" on every import path. Only the watched folder
// keeps that promise: its inbox offers a changed file again once it settles. A file chosen in the
// picker or handed over by Finder, the Dock or Services is never retried, so the user who waited, or
// deleted their copy trusting the app had it, got no meeting.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportNextStep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    // What a writer that paused and then resumed does: more bytes land after the copy took its own.
    model.copyRecordingIntoLibrary = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 4_096))
    }
    return model
}

private func makeRecordingFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportNextStepSource-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("call.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

private let watchedFolderPromise = "will be imported once it is finished"
private let tryAgain = "Try again once it has finished"

@MainActor
@Test("A picked file that was still being written says to try again, not that it will be imported (F551)")
func pickedFileStillBeingWrittenSaysTryAgain() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    // The file picker's call (ContentView's fileImporter).
    let outcome = await model.importRecordings(from: [file], title: "")

    #expect(outcome.firstID == nil)
    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("still being written"))
    #expect(!alert.contains(watchedFolderPromise), "nothing retries a picked file: \(alert)")
    #expect(alert.contains(tryAgain), "\(alert)")
}

@MainActor
@Test("A file from Finder, the Dock or Services that was still being written says to try again (F551)")
func handedOverFileStillBeingWrittenSaysTryAgain() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    // Open With, the Dock, Shortcuts and Services all arrive here (AppEntry -> importExternalFiles).
    await model.importExternalFiles([file])

    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("still being written"))
    #expect(!alert.contains(watchedFolderPromise), "nothing retries a handed-over file: \(alert)")
    #expect(alert.contains(tryAgain), "\(alert)")
}

@MainActor
@Test("A watched-folder file that was still being written keeps the promise, which its inbox keeps (F551 control)")
func watchedFolderFileStillBeingWrittenKeepsThePromise() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    model.watchedFolderLooked(snapshot: nil, ready: [file])
    let delivery = try #require(model.watchedFolderDelivery, "the file was handed to the importer")
    await delivery.value

    #expect(model.store.meetings.isEmpty)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("still being written"))
    #expect(alert.contains(watchedFolderPromise), "\(alert)")
    #expect(!alert.contains(tryAgain), "\(alert)")
}
