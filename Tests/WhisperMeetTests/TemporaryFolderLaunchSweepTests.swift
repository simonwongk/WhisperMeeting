import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F996 — every temporary folder the app names for its process and leaves to a `defer` is removed at the
// next launch once its process has exited: Qwen's decode, a summary's, an answer's, a correction's and
// an embedding's working folders, a segment re-run's clip, the test recording, and the mix and
// speaker-analysis folders. Never a folder whose process exists, never a name the app did not make, and
// never from a test process's real temporary folder (F937).

private let exitedProcess: pid_t = 99_999_999

@Test("A launch's sweep removes each kind of folder a dead process left, and keeps a live one's (F996)")
func theLaunchSweepRemovesEveryKindOfAbandonedFolder() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F996-sweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var abandoned: [String] = []
    var kept: [String] = []
    for prefix in AppModel.launchSweptFolderPrefixes {
        abandoned.append(OwnedTemporaryFolders.name(prefix: prefix, processID: exitedProcess))
        kept.append(OwnedTemporaryFolders.name(prefix: prefix, processID: 1))   // launchd: always alive
        kept.append(OwnedTemporaryFolders.name(prefix: prefix))                 // this process
        kept.append("\(prefix)\(UUID().uuidString)")                            // the old name: no owner to ask
    }
    kept.append("WhisperMeet-Whisper-\(exitedProcess)-\(UUID().uuidString)")   // swept by each Whisper run instead
    kept.append("Unrelated-\(exitedProcess)-\(UUID().uuidString)")
    for name in abandoned + kept {
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 1_024).write(to: folder.appendingPathComponent("decoded.wav"))
    }

    let removed = AppModel.removeAbandonedTemporaryFolders(in: scratch)

    #expect(Set(removed) == Set(abandoned))
    for name in abandoned {
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent(name).path), "\(name) outlived the sweep")
    }
    for name in kept {
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(name).path), "\(name) was removed")
    }
}

@Test("The launch sweep covers Qwen, the local helpers, segment clips and the test recording (F996)")
func theLaunchSweepCoversEveryFeaturesPrefix() {
    let prefixes = Set(AppModel.launchSweptFolderPrefixes)
    for prefix in [QwenASRClient.runFolderPrefix, LocalSummarizer.summaryFolderPrefix, LocalSummarizer.answerFolderPrefix,
                   LocalTranscriptCorrector.workFolderPrefix, LocalEmbedder.workFolderPrefix,
                   AppModel.segmentClipFolderPrefix, AppModel.preflightFolderPrefix,
                   AppModel.mixFolderPrefix, AppModel.diarizationFolderPrefix] {
        #expect(prefixes.contains(prefix), "\(prefix) is never swept")
    }
    // No prefix is the start of another's, so one feature's sweep cannot read another's folder as its own.
    for a in prefixes { for b in prefixes where a != b { #expect(!b.hasPrefix(a), "\(a) is a prefix of \(b)") } }
}

@MainActor
@Test("A segment clip's folder is removed with it, and only a folder the app named for a clip (F996)")
func removingASegmentClipRemovesItsFolder() throws {
    let wavDir = FileManager.default.temporaryDirectory.appendingPathComponent("F996-remove-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: wavDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: wavDir) }
    let wav = wavDir.appendingPathComponent("meeting.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0, count: 48_000), sampleRate: 48_000).write(to: wav)
    let clip = try AppModel.makeSegmentClip(from: wav, startSeconds: 0, endSeconds: 0.5)

    AppModel.removeSegmentClip(clip)

    #expect(!FileManager.default.fileExists(atPath: clip.deletingLastPathComponent().path))
    // A clip URL that is not in a clip folder of the app's: only the file goes, never its folder.
    let loose = wavDir.appendingPathComponent("loose.wav")
    try Data(count: 16).write(to: loose)
    AppModel.removeSegmentClip(loose)
    #expect(!FileManager.default.fileExists(atPath: loose.path))
    #expect(FileManager.default.fileExists(atPath: wav.path), "a folder that is not a clip's was removed")
}

// A source check rather than a launch: `performStartupRecovery` costs about 4 s in a test, and what is
// asserted is only that the sweep sits behind `TestProcess`'s refusal (F937), whose own tests cover it.
@Test("The launch runs the sweep, refused in a test process (F996)")
func theLaunchCallsTheSweepBehindTheTestProcessGuard() throws {
    let app = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(app.contains("if TestProcess.allowsRealAccess(to: Self.launchFolderSweepRefusal) {"))
    #expect(app.contains("Self.removeAbandonedTemporaryFolders(in: scratch)"))
}
