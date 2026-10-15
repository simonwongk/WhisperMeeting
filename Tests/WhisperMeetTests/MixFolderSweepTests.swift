import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F965 — `executeEngine` mixes a several-track (or more-than-two-channel) recording into a temp folder
// of its own, `WhisperMeet-Mix-<UUID>`, and removed it with a `defer`, which a crash or a force-quit
// skips; the mix is about 115 MB per hour of audio, and nothing swept it. Whisper's own run folders have
// carried their process ID and been swept by it since F533 review R7. The mix folder (and speaker
// analysis's workspace, which holds the same mix) is now named the same way, through
// `OwnedTemporaryFolders`, and each engine run first removes the mix folders of processes that have
// exited — never one whose process exists, and never a link.

private let exitedProcess: pid_t = 99_999_999

private final class HandedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    var url: URL? { lock.withLock { value } }
    func set(_ url: URL) { lock.withLock { value = url } }
}

@MainActor
@Test("An engine run names its mix folder for this process, and first removes one a dead process left (F965)")
func anEngineRunSweepsADeadRunsMixFolderAndNamesItsOwn() async throws {
    let temp = FileManager.default.temporaryDirectory
    let abandoned = temp.appendingPathComponent(
        OwnedTemporaryFolders.name(prefix: AppModel.mixFolderPrefix, processID: exitedProcess), isDirectory: true)
    let inUse = temp.appendingPathComponent(
        OwnedTemporaryFolders.name(prefix: AppModel.mixFolderPrefix, processID: 1), isDirectory: true)
    for folder in [abandoned, inUse] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: folder.appendingPathComponent("mixed.wav"))
    }
    defer { for folder in [abandoned, inUse] { try? FileManager.default.removeItem(at: folder) } }
    let root = temp.appendingPathComponent("F965-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Four channels and no layout: mixed before any engine hears it (F942).
    let recording = root.appendingPathComponent("recording.wav")
    try fixturePolyWAV([300.0, 500.0, 700.0, 900.0].map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 2) })
        .write(to: recording)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let handed = HandedURL()
    model.runTranscriptionEngineOverride = { _, url in
        handed.set(url)
        return TranscriptionResult(id: "stub", text: "Hi.", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [])
    }

    _ = try await model.executeEngine(MeetingTranscriptionSelection(engine: .whisperLarge, language: .automatic),
                                      on: recording)

    #expect(!FileManager.default.fileExists(atPath: abandoned.path), "a dead process's mix folder outlived the next engine run")
    #expect(FileManager.default.fileExists(atPath: inUse.path), "a folder whose process exists was removed")
    let url = try #require(handed.url)
    #expect(url != recording, "the four-channel WAV was not mixed")
    let folderName = url.deletingLastPathComponent().lastPathComponent
    #expect(OwnedTemporaryFolders.owner(of: folderName, prefix: AppModel.mixFolderPrefix) == getpid(),
            "the mix folder does not name this process: \(folderName)")
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
            "the run's own mix folder is removed when the run ends")
}

@Test("Every temporary folder that holds a mix is named for its process, and swept before it is made (F965)")
func mixFoldersAreNamedForTheirProcess() throws {
    let app = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(!app.contains("\"WhisperMeet-Mix-\\(UUID()"), "the engine run's mix folder names no owner")
    #expect(!app.contains("\"WhisperMeet-Diarization-\\(UUID()"), "speaker analysis's workspace names no owner")
    #expect(app.contains("OwnedTemporaryFolders.name(prefix: Self.mixFolderPrefix)"), "the engine run does not name its mix folder for this process")
    #expect(app.contains("OwnedTemporaryFolders.name(prefix: AppModel.diarizationFolderPrefix)"), "speaker analysis does not name its workspace for this process")
    #expect(app.contains("OwnedTemporaryFolders.removeAbandoned(in: scratch, prefix: Self.mixFolderPrefix)"), "the engine run does not sweep dead runs' mix folders")
    #expect(app.contains("OwnedTemporaryFolders.removeAbandoned(in: scratch, prefix: AppModel.diarizationFolderPrefix)"), "speaker analysis does not sweep dead runs' workspaces")
}
