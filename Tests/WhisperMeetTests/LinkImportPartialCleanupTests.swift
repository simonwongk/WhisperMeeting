import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F894 — a link import recovered from its complete download kept the WAV ffmpeg never finished beside
// it: gigabytes for a multi-hour import, counted against the meeting until the meeting is deleted.
// Once the meeting is indexed from the download, recovery now removes that WAV — only when both are
// measured and the WAV holds less than the download (the audio its bytes hold when ffmpeg never
// finished it, or since F911 the length a complete header declares), only when the kernel says no
// process has it or the download open, and only if it is still the file that was measured. The
// download is never removed, and a meeting made from its WAV keeps the download beside it: recovery
// never deletes a complete copy (Shrink removes it, when it can show the recording covers it, F947).
//
// Review of F894: the first version took "ffmpeg never finished it" to mean "it holds less" without
// measuring the download, and on the path where the conversion had just failed that removed the only
// audio anything had decoded. A download that cannot be measured now keeps the WAV.

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
@Test("The unfinished WAV beside a download macOS cannot measure is kept when its conversion fails (F894)")
func anUnfinishedWAVBesideAnUnfinishedImportIsKept() async throws {
    // The download is the one that has just failed to convert, and nothing can say how long it is, so
    // nothing shows the WAV holds less. Keeping it costs disk space on an entry already marked failed.
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
    #expect(exists("recording.wav", in: folder), "a WAV no measurement showed to hold less was removed")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.webm")) == webmDownload, "the download changed")
}

@MainActor
@Test("A WAV beside a download nothing can read is kept: it may be the only decoded audio (F894)")
func aWAVBesideAnUnreadableDownloadIsKept() async throws {
    // The review's P3: 8 KB of zeros named `recording.m4a`, and a WAV ffmpeg never finished that holds
    // 4 s of real audio. The conversion fails, so the entry is an unfinished import against the
    // download, and the WAV is the only audio anything has decoded.
    let (root, id, folder) = try makeInterruptedImport("unreadable") { folder in
        try Data(repeating: 0x00, count: 8_192).write(to: folder.appendingPathComponent("recording.m4a"))
        try unfinishedWAV(seconds: 4).write(to: folder.appendingPathComponent("recording.wav"))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Data(contentsOf: folder.appendingPathComponent("recording.wav"))
    let model = makeModel(root: root) { _ in throw MediaDownloadError.extractionFailed }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not kept as an entry")
    try #require(meeting.recordingPath.hasSuffix("recording.m4a"), "indexed against \(meeting.recordingPath)")
    #expect(exists("recording.wav", in: folder), "the only decoded audio was removed")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.wav")) == before)
}

/// A meeting made from the download beside `wav`, indexed directly so the cleanup can be asked alone.
@MainActor
private func indexedFromItsDownload(_ label: String, wav: Data) throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let (root, id, folder) = try makeInterruptedImport(label) { folder in
        try writeM4A(seconds: 6, to: folder.appendingPathComponent("recording.m4a"))
        try wav.write(to: folder.appendingPathComponent("recording.wav"))
    }
    let model = makeModel(root: root) { _ in throw MediaDownloadError.extractionFailed }
    model.store.upsert(MeetingRecord(
        id: id, title: "Interrupted import", createdAt: Date(), duration: 6,
        recordingPath: model.store.relativeRecordingPath(for: folder.appendingPathComponent("recording.m4a")),
        status: .recorded
    ))
    return (root, model, id, folder)
}

@MainActor
@Test("A finished WAV as long as the download it sits beside is kept, though the meeting is the download (F894)")
func aFullWAVBesideTheDownloadIsKept() async throws {
    // The review's P1. A writer the probes could not see that finished between the settlement and the
    // cleanup leaves exactly this: the WAV is complete, and only measuring it shows that.
    let (root, model, id, folder) = try indexedFromItsDownload("full", wav: finishedWAV(seconds: 6))
    defer { try? FileManager.default.removeItem(at: root) }

    await model.removeUnfinishedExtraction(of: try #require(model.store.meeting(id: id)))

    #expect(exists("recording.wav", in: folder), "a WAV holding all of the download was removed")
}

@MainActor
@Test("The unfinished WAV is kept while a process has the download open (F894)")
func anUnfinishedWAVIsKeptWhileTheDownloadIsHeld() async throws {
    // The review's P2: a reader of the download is a writer of the WAV, as ffmpeg is.
    let (root, model, id, folder) = try indexedFromItsDownload("held", wav: try unfinishedWAV(seconds: 2))
    defer { try? FileManager.default.removeItem(at: root) }
    model.importFileOpenState = { $0.lastPathComponent == "recording.m4a" ? .held : .notHeld }

    await model.removeUnfinishedExtraction(of: try #require(model.store.meeting(id: id)))

    #expect(exists("recording.wav", in: folder), "the WAV was removed while a process held the download")
}

@MainActor
@Test("A WAV put in place after it was measured is not the one removed (F894)")
func aWAVReplacedAfterItWasMeasuredIsKept() async throws {
    // Review of F894, finding 3: the checks read `recording.wav` by path, the probes take a moment, and
    // the removal was by path. Another copy of WhisperMeet finishing its conversion (F945) renames a
    // finished WAV over that name in between. Here the open-file probe does it, between the two.
    let (root, model, id, folder) = try indexedFromItsDownload("replaced", wav: try unfinishedWAV(seconds: 2))
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = folder.appendingPathComponent("recording.wav")
    let finished = finishedWAV(seconds: 6)
    model.importFileOpenState = { url in
        if url.lastPathComponent == "recording.wav" {
            let staged = folder.appendingPathComponent("recording.extracting.other.wav")
            try? finished.write(to: staged)
            _ = rename(staged.path, wav.path)
        }
        return .notHeld
    }

    await model.removeUnfinishedExtraction(of: try #require(model.store.meeting(id: id)))

    #expect(exists("recording.wav", in: folder), "the finished WAV another copy put in place was removed")
    #expect((try? Data(contentsOf: wav)) == finished)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    #expect(left.sorted() == [MediaSource.sidecarFilename, "recording.m4a", "recording.wav"].sorted(), "\(left)")
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
