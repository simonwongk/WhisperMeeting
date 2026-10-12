import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F894 — a link import recovered from its complete download kept the WAV ffmpeg never finished beside
// it: gigabytes for a multi-hour import, counted against the meeting until the meeting is deleted.
// Once the meeting is indexed from the download, recovery now removes that WAV — only when it is shown
// to hold less than the download (ffmpeg's placeholder header, or since F911 a complete header shorter
// than the download), and only when the kernel says no process has it or the download open. The
// download is never removed, and a meeting made from its WAV keeps the download beside it: recovery
// never deletes a complete copy (Shrink removes it, when it can show the recording covers it, F947).

private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
}

private func finishedWAV(seconds: Double) -> Data {
    WAVWriter.wavData(from: tone(seconds: seconds), sampleRate: 16_000)
}

/// What ffmpeg has written while it is still extracting: RIFF and data sizes left at 0xFFFFFFFF.
private func unfinishedWAV(seconds: Double) throws -> Data {
    var data = finishedWAV(seconds: seconds)
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

/// Bytes AVFoundation cannot open, standing for YouTube's usual Opus in WebM (format 251).
private let webmDownload = Data("a complete WebM download macOS cannot open".utf8)

/// `Recordings/<id>/` holding a link import's `source.json`, with `write` adding its files.
private func makeInterruptedImport(_ label: String, _ write: (URL) throws -> Void) throws -> (root: URL, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F894-\(label)-\(UUID().uuidString)", isDirectory: true)
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
    try write(folder)
    return (root, id, folder)
}

@MainActor
private func makeModel(root: URL, conversion: @escaping @Sendable (URL) throws -> URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    model.finishInterruptedLinkImportExtraction = { try conversion($0) }
    return model
}

private func exists(_ name: String, in folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
}

@MainActor
@Test("The unfinished WAV beside a download recovered as it is, is removed and the download kept (F894)")
func anUnfinishedWAVBesideAMeasuredDownloadIsRemoved() async throws {
    let (root, id, folder) = try makeInterruptedImport("placeholder") { folder in
        try writeM4A(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try unfinishedWAV(seconds: 2).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let download = try Data(contentsOf: folder.appendingPathComponent("recording.m4a"))
    let model = makeModel(root: root) { _ in throw MediaDownloadError.extractionFailed }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.m4a"), "indexed against \(meeting.recordingPath)")
    #expect(!exists("recording.wav", in: folder), "the WAV ffmpeg never finished was kept")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.m4a")) == download, "the download changed")
    #expect(exists(MediaSource.sidecarFilename, in: folder))
}

@MainActor
@Test("A shorter finished WAV, once the download is recovered instead, is removed and the download kept (F894, F911)")
func aShorterWAVBesideAMeasuredDownloadIsRemoved() async throws {
    let (root, id, folder) = try makeInterruptedImport("shorter") { folder in
        try writeM4A(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try finishedWAV(seconds: 3).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let download = try Data(contentsOf: folder.appendingPathComponent("recording.m4a"))
    let model = makeModel(root: root) { _ in throw MediaDownloadError.extractionFailed }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.m4a"), "indexed against \(meeting.recordingPath)")
    #expect(!exists("recording.wav", in: folder), "the shorter WAV was kept beside the download it falls short of")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.m4a")) == download, "the download changed")
}

@MainActor
@Test("The unfinished WAV beside a download whose conversion failed is removed, and the download kept (F894)")
func anUnfinishedWAVBesideAnUnfinishedImportIsRemoved() async throws {
    let (root, id, folder) = try makeInterruptedImport("unfinished") { folder in
        try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
        try unfinishedWAV(seconds: 2).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(root: root) { _ in throw MediaDownloadError.ffmpegMissing }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not kept as an entry")
    try #require(meeting.title == AppModel.unfinishedLinkImportTitle(host: "example.com"))
    #expect(meeting.recordingPath.hasSuffix("recording.webm"))
    #expect(!exists("recording.wav", in: folder), "the WAV ffmpeg never finished was kept")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload, "the download changed")
}

@MainActor
@Test("A meeting made from its WAV keeps the download beside it: recovery never deletes a complete copy (F894)")
func aMeetingMadeFromItsWAVKeepsTheDownload() async throws {
    // The download macOS cannot open is converted, and the finished WAV is the meeting: both are
    // complete, so both stay (Shrink can remove the download, F947).
    let (root, id, folder) = try makeInterruptedImport("converted") { folder in
        try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
        try unfinishedWAV(seconds: 2).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(root: root) { download in
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try finishedWAV(seconds: 6).write(to: finished)
        return finished
    }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    #expect(exists("recording.wav", in: folder))
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload, "the download was touched")
}

@MainActor
@Test("When the kernel cannot say whether the WAV is open, it is kept (F894)")
func aPartialWAVIsKeptWhenNoOneCanSayItIsClosed() async throws {
    // Removal needs the kernel's positive "no process has it open". An answer it cannot give leaves
    // the file, which costs disk space and nothing else.
    let (root, id, folder) = try makeInterruptedImport("unknown") { folder in
        try writeM4A(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try unfinishedWAV(seconds: 2).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Data(contentsOf: folder.appendingPathComponent("recording.wav"))
    let model = makeModel(root: root) { _ in throw MediaDownloadError.extractionFailed }
    model.importFileOpenState = { _ in .unknown }

    await model.performStartupRecovery()

    try #require(model.store.meeting(id: id)?.recordingPath.hasSuffix("recording.m4a") == true)
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.wav")) == before, "a WAV no one could vouch for was removed")
}
