import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F996 — Qwen's decode folder (`WhisperMeet-Qwen-<UUID>`, the size of the recording's decode), the
// summarizer's, the answer's, the corrector's, the embedder's, the test recording's and each segment
// re-run's clip were removed only by a `defer`, which a crash or a force-quit skips, and their names
// carried no owner, so nothing could tell one a dead process left from one in use. Each is now named
// for its process (`OwnedTemporaryFolders`, as Whisper's run folders and the mix folder are since
// F533 R7 and F965), and each launch removes the ones whose process has exited.
//
// These two compile against the code before the fix, so their RED is behavioural.

@Test("No temporary folder or file the app makes is named by a bare UUID: each names its process (F996)")
func everyTemporaryNameInTheSourcesNamesItsProcess() throws {
    // Derived, not listed (AGENTS.md "Derive the list"): every `"WhisperMeet-<Feature>-\(UUID()` in
    // the sources, whatever the feature, is a name with no owner that no sweep can ever remove.
    var offenders: [String] = []
    for directory in ["Sources/WhisperCore", "Sources/WhisperMeet"] {
        for file in try SourceAssertion.swiftFileURLs(under: directory) {
            let relative = String(file.path.dropFirst(SourceAssertion.repositoryRoot.path.count + 1))
            for line in try SourceAssertion.uncommentedLines(relative)
            where line.text.range(of: #""WhisperMeet-[A-Za-z]+-\\\(UUID\(\)"#, options: .regularExpression) != nil {
                offenders.append("\(relative):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(offenders.isEmpty, "temporary names with no owner:\n\(offenders.joined(separator: "\n"))")
}

@MainActor
@Test("A segment re-run's clip is written in a folder named for this process (F996)")
func aSegmentClipLivesInAFolderNamedForThisProcess() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("F996-clip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = dir.appendingPathComponent("meeting.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0, count: 48_000 * 2), sampleRate: 48_000).write(to: wav)

    let clip = try AppModel.makeSegmentClip(from: wav, startSeconds: 0.5, endSeconds: 1.5)
    let folder = clip.deletingLastPathComponent()
    defer {
        // Only ever this test's own clip: its folder, when it has one of its own, else the file.
        if folder.lastPathComponent.hasPrefix("WhisperMeet-Segment-") {
            try? FileManager.default.removeItem(at: folder)
        } else {
            try? FileManager.default.removeItem(at: clip)
        }
    }

    #expect(FileManager.default.fileExists(atPath: clip.path))
    #expect(OwnedTemporaryFolders.owner(of: folder.lastPathComponent, prefix: "WhisperMeet-Segment-") == getpid(),
            "the clip is not in a folder named for this process: \(clip.path)")
}
