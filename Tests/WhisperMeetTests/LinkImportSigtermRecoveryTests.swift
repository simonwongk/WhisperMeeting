import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F911 — a link import's extraction stopped by SIGTERM comes back half-length.
//
// yt-dlp runs ffmpeg from the complete download straight into `recording.wav` and deletes the
// download only when ffmpeg has finished. launchd sends every process SIGTERM at a shutdown, restart
// or logout, and ffmpeg handles it by finishing cleanly, header included: lane U's probe, yt-dlp's
// exact vector with the installed ffmpeg 8.1.2, SIGTERM two seconds into an hour's WebM, left a
// `recording.wav` whose header was complete and consistent and declared 1,813 s of the 3,600 s
// (`.claude/wave5/gates/lane-U/r2-ffmpeg-sigterm-probe.log`). Recovery took a complete header to mean
// a finished extraction and indexed that WAV, with nothing about the missing half. So whenever a
// finished WAV sits beside the complete download, the download decides: compared where macOS can
// measure it, converted again where it cannot. Each outcome is pinned here through
// `performStartupRecovery`, over a temp library.

private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
}

/// What ffmpeg leaves when SIGTERM stops it part way: a WAV whose header is complete and consistent,
/// declaring only the audio it had written.
private func sigtermFinishedWAV(seconds: Double) -> Data {
    WAVWriter.wavData(from: tone(seconds: seconds), sampleRate: 16_000)
}

/// A download macOS can measure: AAC in M4A, the container of YouTube's format 140.
private func writeM4ADownload(seconds: Double, to url: URL) throws {
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

private final class ConversionLog: @unchecked Sendable {
    var downloads: [String] = []
}

/// `Recordings/<id>/` holding a link import's `source.json`, with `write` adding its files.
private func makeInterruptedImport(in root: URL, _ write: (URL) throws -> Void) throws -> (id: UUID, folder: URL) {
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
    return (id, folder)
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F911-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func makeModel(root: URL, log: ConversionLog, conversion: @escaping @Sendable (URL) throws -> URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    model.finishInterruptedLinkImportExtraction = { download in
        log.downloads.append(download.lastPathComponent)
        return try conversion(download)
    }
    return model
}

@MainActor
@Test("A shorter finished WAV beside a download macOS can measure is recovered from the download (F911)")
func aShorterWAVLosesToAMeasuredDownload() async throws {
    let root = try makeRoot("measured")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedImport(in: root) { folder in
        try writeM4ADownload(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try sigtermFinishedWAV(seconds: 3).write(to: folder.appendingPathComponent("recording.wav"))
    }
    let download = try Data(contentsOf: folder.appendingPathComponent("recording.m4a"))
    let log = ConversionLog()
    let model = makeModel(root: root, log: log) { _ in throw MediaDownloadError.extractionFailed }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.recordingPath.hasSuffix("recording.m4a"), "indexed against \(meeting.recordingPath)")
    #expect(abs(meeting.duration - 6) < 0.5, "the meeting is \(meeting.duration) s of a 6 s download")
    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
    #expect(meeting.source?.host == "example.com")
    #expect(log.downloads.isEmpty, "a download macOS can measure was converted: \(log.downloads)")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.m4a")) == download, "the download changed")
}

@MainActor
@Test("A shorter finished WAV beside a download macOS cannot open is replaced by converting the download again (F911)")
func aShorterWAVBesideAWebMIsConvertedAgain() async throws {
    let root = try makeRoot("webm")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedImport(in: root) { folder in
        try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
        try sigtermFinishedWAV(seconds: 3).write(to: folder.appendingPathComponent("recording.wav"))
    }
    let log = ConversionLog()
    // The conversion as the real one ends: a finished WAV of the whole download, renamed over the old one.
    let model = makeModel(root: root, log: log) { download in
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try sigtermFinishedWAV(seconds: 6).write(to: finished)
        return finished
    }

    await model.performStartupRecovery()

    #expect(log.downloads == ["recording.webm"], "the conversion was asked about \(log.downloads)")
    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    #expect(abs(meeting.duration - 6) < 0.05, "the meeting is \(meeting.duration) s of a 6 s download")
    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
    #expect(meeting.recoveryWarning == nil, "\(meeting.recoveryWarning ?? "")")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload, "the download changed")
}

@MainActor
@Test("A finished WAV that cannot be checked against its download is kept, and says so (F911)")
func aWAVThatCannotBeCheckedIsKeptWithACaveat() async throws {
    let root = try makeRoot("unchecked")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedImport(in: root) { folder in
        try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
        try sigtermFinishedWAV(seconds: 3).write(to: folder.appendingPathComponent("recording.wav"))
    }
    let wav = try Data(contentsOf: folder.appendingPathComponent("recording.wav"))
    let log = ConversionLog()
    let model = makeModel(root: root, log: log) { _ in throw MediaDownloadError.ffmpegMissing }

    await model.performStartupRecovery()

    #expect(log.downloads == ["recording.webm"])
    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    let caveat = AppModel.uncheckedLinkImportWarning(reason: MediaDownloadError.ffmpegMissing.localizedDescription)
    // Playable and transcribable, as it was — but no longer presented as the whole import.
    #expect(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
    #expect(abs(meeting.duration - 3) < 0.05)
    #expect(meeting.recoveryWarning == caveat, "\(meeting.recoveryWarning ?? "nil")")
    #expect(model.alertMessage?.contains(caveat) == true, "\(model.alertMessage ?? "nil")")
    // Deleting the entry deletes the folder, and the folder holds the only complete download.
    #expect(!caveat.localizedCaseInsensitiveContains("delete"))
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.wav")) == wav, "the WAV changed")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload, "the download changed")
}

@MainActor
@Test("A finished extraction beside its download is still the recording, and both are kept (F911)")
func aFinishedExtractionBesideItsDownloadIsStillUsed() async throws {
    // ffmpeg finished and the app stopped before yt-dlp deleted the download: the WAV holds all of it.
    let root = try makeRoot("finished")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedImport(in: root) { folder in
        try writeM4ADownload(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try sigtermFinishedWAV(seconds: 6).write(to: folder.appendingPathComponent("recording.wav"))
    }
    let log = ConversionLog()
    let model = makeModel(root: root, log: log) { _ in throw MediaDownloadError.extractionFailed }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    #expect(abs(meeting.duration - 6) < 0.05)
    #expect(meeting.recoveryWarning == nil)
    #expect(log.downloads.isEmpty)
    for name in ["recording.wav", "recording.m4a", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
}

@MainActor
@Test("A cancelled second conversion leaves the folder for the next launch (F911)")
func aCancelledReconversionLeavesTheFolder() async throws {
    let root = try makeRoot("cancelled")
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, folder) = try makeInterruptedImport(in: root) { folder in
        try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
        try sigtermFinishedWAV(seconds: 3).write(to: folder.appendingPathComponent("recording.wav"))
    }
    let wav = try Data(contentsOf: folder.appendingPathComponent("recording.wav"))
    let log = ConversionLog()
    let model = makeModel(root: root, log: log) { _ in throw CancellationError() }

    await model.performStartupRecovery()

    try #require(log.downloads == ["recording.webm"], "the conversion was never asked")
    #expect(model.store.meetings.isEmpty, "a cancelled recovery indexed \(model.store.meetings.map(\.recordingPath))")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.wav")) == wav)
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload)
}
