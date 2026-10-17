import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F946 — startup recovery left a folder alone only when its files grew between two samples 400 ms
// apart (F279, F453). A link import's writer that is alive but stalled for longer — ffmpeg extracting
// for an app that crashed, or a second copy of WhisperMeet still importing — read as dead, and
// recovery chose the complete download over the WAV ffmpeg had not finished. An open file is a
// positive sign of a writer: ffmpeg holds the download and the WAV while it runs, and yt-dlp its
// `.part`. Here a child process holds the WAV open and writes nothing, so the growth probe sees no
// growth and only the open file can say the folder is live. Everything uses the real probes.

private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
}

/// What ffmpeg's WAV holds while it is still extracting: RIFF and data sizes left at 0xFFFFFFFF.
private func unfinishedWAV(seconds: Double) throws -> Data {
    var data = WAVWriter.wavData(from: tone(seconds: seconds), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    data.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(data.range(of: Data("data".utf8)))
    data.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    return data
}

/// A download macOS can measure: AAC in M4A, YouTube's format 140.
private func writeM4A(seconds: Double, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let samples = tone(seconds: seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try #require(buffer.floatChannelData?[0])
    for (index, sample) in samples.enumerated() { channel[index] = sample }
    try file.write(from: buffer)
}

/// Polls `condition` until it holds or 30 s pass; the caller `#require`s the result.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

@MainActor
private func makeModel(root: URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    model.finishInterruptedLinkImportExtraction = { _ in throw MediaDownloadError.extractionFailed }
    return model
}

@MainActor
@Test("A link import whose WAV a process still holds open is left alone, though nothing grows (F946)")
func aLinkImportHeldOpenIsLeftAlone() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F946-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind, pageURL: "https://example.com/watch?v=abc123", host: "example.com",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try writeM4A(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
    let wav = folder.appendingPathComponent("recording.wav")
    try unfinishedWAV(seconds: 2).write(to: wav)
    let before = try Data(contentsOf: wav)

    // A stalled writer: holds the WAV open for appending and writes nothing.
    let started = scratch.appendingPathComponent("holder-started")
    let holder = ProcessGroupRunner()
    defer { holder.kill() }
    Task {
        _ = try? await holder.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 3>>\"$1\"; : > \"$2\"; sleep 60", "sh", wav.path, started.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0
        )
    }
    try #require(await eventually { FileManager.default.fileExists(atPath: started.path) }, "the holder never started")
    try #require(RecordingFolderLiveness.openState(of: wav.path) == .held, "the kernel does not see the holder")

    let model = makeModel(root: root)
    await model.performStartupRecovery()

    #expect(model.store.meetings.isEmpty, "a folder whose writer is alive was indexed: \(model.store.meetings.map(\.recordingPath))")
    // F973: named by the kernel's own answer. The holder is `sh` with `sleep` as its child, both
    // holding the WAV through the inherited descriptor; `sleep` is the one alive for the whole wait.
    let alert = model.alertMessage ?? "nil"
    #expect(alert.contains("A link import on this Mac is still being written by "), "\(alert)")
    #expect(alert.contains("“sleep”"), "the notice does not name the process holding the import: \(alert)")
    #expect(try Data(contentsOf: wav) == before, "the WAV was touched")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))

    // Once the writer has gone, the next launch recovers it: the hold, and nothing else, deferred it.
    holder.kill()
    try #require(await eventually { RecordingFolderLiveness.openState(of: wav.path) == .notHeld },
                 "the holder never let go of the WAV")
    let next = makeModel(root: root)
    await next.performStartupRecovery()
    let meeting = try #require(next.store.meeting(id: id), "the import was not recovered once nothing held it")
    #expect(meeting.recordingPath.hasSuffix("recording.m4a"), "indexed against \(meeting.recordingPath)")
}

@MainActor
@Test("The launch notice names the process holding a link import's file, so the user knows what to quit (F973)")
func theStillBeingWrittenNoticeNamesTheHolder() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F973-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind, pageURL: "https://example.com/watch?v=abc123", host: "example.com",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try writeM4A(seconds: 2, to: folder.appendingPathComponent("recording.m4a"))
    try unfinishedWAV(seconds: 1).write(to: folder.appendingPathComponent("recording.wav"))

    let model = makeModel(root: root)
    // The stand-in: two processes hold the WAV, and nothing else is open.
    model.importFileOpenState = { $0.lastPathComponent == "recording.wav" ? .held : .notHeld }
    model.importFileHolderNames = { $0.lastPathComponent == "recording.wav" ? ["yt-dlp", "ffmpeg"] : [] }
    await model.performStartupRecovery()

    #expect(model.store.meetings.isEmpty, "a held import was indexed")
    let alert = model.alertMessage ?? "nil"
    #expect(alert.contains(AppModel.linkImportStillBeingWritten(heldBy: ["ffmpeg", "yt-dlp"])), "\(alert)")
    #expect(alert.contains("still being written by “ffmpeg” and “yt-dlp”"), "\(alert)")
    #expect(alert.contains("quit “ffmpeg” and “yt-dlp”"), "\(alert)")
}

@MainActor
@Test("With no holder named, the notice is the plain sentence it always was (F973)")
func theStillBeingWrittenNoticeWithoutAHolder() {
    #expect(AppModel.linkImportStillBeingWritten(heldBy: []) == AppModel.linkImportStillBeingWritten)
    #expect(AppModel.linkImportStillBeingWritten(heldBy: ["ffmpeg"]).contains("by “ffmpeg”, so it was left alone"))
}
