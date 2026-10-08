import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F453 part 2, through startup recovery: the folder a link import leaves when the app dies while
// ffmpeg is extracting its audio holds the complete download and a `recording.wav` with ffmpeg's
// placeholder header (ImportCandidateChoiceTests says why). Two outcomes are possible at the next
// launch, and both are pinned here through `performStartupRecovery`:
//
// - nothing is writing it any more (a power loss, or the extraction was killed): the meeting is
//   indexed against the complete download, never the partial WAV;
// - ffmpeg is still writing it, because it is in its own process group and outlived the app:
//   the folder is left alone, with a sentence that says what will happen to it. Adopting it would
//   point the meeting at the download yt-dlp deletes the moment ffmpeg finishes.

private final class SampleCounter: @unchecked Sendable {
    var calls = 0
}

/// `Recordings/<id>/` as the interrupted import left it.
private func makeInterruptedExtraction(in root: URL) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind,
        pageURL: "https://example.com/watch?v=abc123",
        host: "example.com",
        videoID: "abc123",
        uploader: "Example Channel",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try Data("a complete downloaded file".utf8).write(to: folder.appendingPathComponent("recording.webm"))
    var partial = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    partial.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(partial.range(of: Data("data".utf8)))
    partial.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    try partial.write(to: folder.appendingPathComponent("recording.wav"))
    return (id, folder)
}

@MainActor
private func makeModel(root: URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    return model
}

@MainActor
@Test("An import interrupted mid-extraction is recovered from its complete download (F453)")
func anInterruptedExtractionRecoversTheDownload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-extraction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, _) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.recordingPath.hasSuffix("recording.webm"), "indexed against \(meeting.recordingPath)")
    #expect(meeting.source?.host == "example.com")
}

@MainActor
@Test("An import still being extracted by a writer that outlived the app is left alone, and says so (F453)")
func anExtractionStillRunningIsLeftAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-extracting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    // ffmpeg appending to the WAV between recovery's two samples, without a clock to race.
    let counter = SampleCounter()
    model.sampleRecordingFolderLiveness = { _ in
        counter.calls += 1
        return RecordingFolderLiveness.Sample(trackBytes: ["recording.wav": Int64(counter.calls) * 65_536])
    }

    await model.performStartupRecovery()

    try #require(counter.calls >= 2, "recovery never sampled the folder twice")
    #expect(model.store.meetings.isEmpty, "a folder still being written was indexed")
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was touched")
    }
    let alert = model.alertMessage ?? ""
    #expect(alert.contains(AppModel.linkImportStillBeingWritten), "\(alert)")
    #expect(!alert.contains(AppModel.recordingStillInProgress),
            "an import was described as a recording that will be added when it stops: \(alert)")
}
