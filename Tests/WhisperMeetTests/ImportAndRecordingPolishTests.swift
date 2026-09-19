import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F344 — the small items from the 2026-09-19 review that change what the user sees.

@Test("A folder named like a recording is not importable (F344)")
func directoryNamedLikeARecordingIsRejected() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F344-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("album.mp3", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("call.m4a")
    try Data("not really audio, but a file".utf8).write(to: real)

    #expect(!ExternalFileIntake.isImportable(bundle), "copying a whole tree to fail at duration load")
    #expect(ExternalFileIntake.isImportable(real))
    // A path that does not exist yet is still importable: the copy reports its own failure.
    #expect(ExternalFileIntake.isImportable(URL(fileURLWithPath: "/nowhere/later.wav")))
}

@MainActor
@Test("An Open With that contains nothing readable says so (F344)")
func openWithNothingReadableIsReported() async {
    let lifecycle = AppLifecycle()
    var rejected: [[URL]] = []
    lifecycle.onRejectedFiles = { rejected.append($0) }
    lifecycle.onStartupRecovery = {}
    lifecycle.onOpenFiles = { _ in }
    await lifecycle.runStartupRecoveryOnce()

    lifecycle.open([URL(fileURLWithPath: "/a/minutes.pdf")])
    #expect(rejected.map { $0.map(\.lastPathComponent) } == [["minutes.pdf"]])

    // A mixed drop stays silent: the readable half is being imported, which is the answer.
    lifecycle.open([URL(fileURLWithPath: "/a/call.m4a"), URL(fileURLWithPath: "/a/notes.pdf")])
    #expect(rejected.count == 1)
    await lifecycle.deliverPendingFiles()
}

@MainActor
@Test("Stop pressed while the recording is still starting says so (F344)")
func stopWhileStartingIsReported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F344-stop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: "F344.\(UUID().uuidString)")!)
    model.setActiveMeetingIDForTesting(UUID())
    model.setRecordingStateForTesting(.starting)

    #expect(await model.stopRecording(title: "") == nil)
    #expect(model.alertMessage?.contains("still starting") == true,
            "⌘R during a slow SCShareableContent.current looked like a key that did nothing")
}

@Test("An at-risk warning answers for itself, and the rollup agrees (F344)")
func warningsCarryTheirOwnRisk() {
    for warning in [RecordingHealthWarning.microphoneCaptureStopped, .systemAudioCaptureStopped, .lowStorage] {
        #expect(warning.isAtRisk)
    }
    for warning in [RecordingHealthWarning.microphoneClipping, .systemAudioClipping, .systemAudioNotDetected, .approachingLengthLimit] {
        #expect(!warning.isAtRisk)
    }
    let snapshot = RecordingHealthSnapshot(
        microphoneLevel: RecordingAudioLevel(rms: 0, peak: 0),
        systemAudioLevel: RecordingAudioLevel(rms: 0, peak: 0),
        availableStorageBytes: nil,
        warnings: [.microphoneClipping, .lowStorage]
    )
    #expect(snapshot.overallStatus == .atRisk)
    var announcer = RecordingRiskAnnouncer()
    #expect(announcer.announcement(for: snapshot)?.contains("storage") == true)
}
