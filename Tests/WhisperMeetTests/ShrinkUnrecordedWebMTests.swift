import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F962 — a WebM link import recovered by a build between `5b203a4` (F453's conversion) and F947's record
// holds the converted WAV and the WebM but no `download-conversion.json`, and AVAudioFile cannot measure
// a WebM, so Shrink refused it for good (fail-closed; about 172 MB an hour kept). When Shrink measures
// such a folder, the download is now measured with the installed ffprobe (`measureDownloadForShrink`,
// here stubbed) and the answer recorded as F947 records a conversion's, once; a download nothing can
// measure is still refused, asked about once a session, and nothing is written for it.

private func tone(seconds: Double, rate: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
}

/// What ffmpeg's WAV holds while it is still extracting: RIFF and data sizes left at 0xFFFFFFFF.
private func unfinishedWAV() throws -> Data {
    var data = WAVWriter.wavData(from: tone(seconds: 1, rate: 16_000), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    data.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(data.range(of: Data("data".utf8)))
    data.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    return data
}

/// Bytes AVFoundation cannot open, standing for YouTube's usual Opus in WebM.
private let webmDownload = Data(repeating: 0x1A, count: 4_096)

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var count: Int { lock.withLock { urls.count } }
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
}

/// A link import recovered by a build before F947: the converted 6 s WAV is the meeting, the WebM is
/// beside it, and there is no record of the conversion.
@MainActor
private func recoveredWebMImportWithoutARecord(_ label: String) async throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F962-\(label)-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind, pageURL: "https://example.com/watch?v=abc123", host: "example.com",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try webmDownload.write(to: folder.appendingPathComponent("recording.webm"))
    try unfinishedWAV().write(to: folder.appendingPathComponent("recording.wav"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.crashReportsSince = { _ in [] }
    model.finishInterruptedLinkImportExtraction = { download in
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: tone(seconds: 6, rate: 16_000), sampleRate: 16_000).write(to: finished)
        return finished
    }
    model.availableBytesForShrink = { _ in .max }
    await model.performStartupRecovery()
    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    // The earlier build wrote no record.
    let record = folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename)
    try FileManager.default.removeItem(at: record)
    try #require(!FileManager.default.fileExists(atPath: record.path))
    return (root, model, id, folder)
}

@MainActor
@Test("A WebM recovered before F947's record is measured when Shrink looks, the length recorded once, and the meeting shrinks (F962)")
func anUnrecordedWebMIsMeasuredRecordedAndShrunk() async throws {
    let (root, model, id, folder) = try await recoveredWebMImportWithoutARecord("shrinks")
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = Asked()
    model.measureDownloadForShrink = { url in asked.add(url); return 6 }
    let record = folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename)

    await model.refreshStorage(ids: [id])
    let meeting = try #require(model.store.meeting(id: id))
    #expect(model.shrinkUnavailability(for: meeting) == nil,
            "\(String(describing: model.shrinkUnavailability(for: meeting)?.message))")
    #expect(asked.count == 1, "asked \(asked.count) times")
    let written = try #require(try? JSONDecoder().decode(
        InterruptedLinkImportExtraction.ConvertedDownload.self, from: Data(contentsOf: record)), "no record was written")
    #expect(written.download == "recording.webm")
    #expect(written.downloadBytes == Int64(webmDownload.count))
    #expect(written.seconds == 6)
    // Recorded, so the next look reads the record and asks nothing.
    await model.refreshStorage(ids: [id])
    #expect(asked.count == 1, "asked again after the length was recorded")

    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let shrunk = try #require(model.store.meeting(id: id))
    #expect(shrunk.recordingPath.hasSuffix("recording.m4a"), "\(shrunk.recordingPath); \(model.alertMessage ?? "")")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path), "the WebM was kept")
}

@MainActor
@Test("A WebM nothing can measure is still kept, asked about once and recorded as nothing; one measured longer than the recording is kept with its length recorded (F962)")
func anUnmeasurableOrLongerWebMIsKept() async throws {
    let (root, model, id, folder) = try await recoveredWebMImportWithoutARecord("kept")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename)
    let asked = Asked()
    model.measureDownloadForShrink = { url in asked.add(url); return nil }

    await model.refreshStorage(ids: [id])
    #expect(model.shrinkUnavailability(for: try #require(model.store.meeting(id: id)))
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: nil))
    #expect(!FileManager.default.fileExists(atPath: record.path), "a record was written for a download nothing measured")
    #expect(asked.count == 1)
    await model.refreshStorage(ids: [id])
    #expect(asked.count == 1, "a download ffprobe could not measure was asked about again this session")

    // Another session: the measurement says the download is longer than the 6 s recording.
    let later = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    later.availableBytesForShrink = { _ in .max }
    later.measureDownloadForShrink = { _ in 7 }
    await later.refreshStorage(ids: [id])
    #expect(later.shrinkUnavailability(for: try #require(later.store.meeting(id: id)))
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: 7))
    let written = try #require(try? JSONDecoder().decode(
        InterruptedLinkImportExtraction.ConvertedDownload.self, from: Data(contentsOf: record)))
    #expect(written.seconds == 7)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path))
}

/// Writes `seconds` of a sine as Opus in WebM with the installed ffmpeg, through the async runner.
private func makeOpusWebM(at url: URL, seconds: Int, ffmpeg: URL) async throws {
    let outcome = try await ProcessGroupRunner().run(
        executableURL: ffmpeg,
        arguments: ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=\(seconds)", "-c:a", "libopus", url.path],
        environment: MediaDownloadClient.makeEnvironment(),
        stallTimeout: 0
    )
    try #require(outcome.exitStatus == 0, "could not make the WebM fixture: \(outcome.output)")
}

@Test(
    "The installed ffprobe measures a real WebM/Opus download, and answers nothing for a file that is not media or when it is not installed (F962)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFprobeMeasuresAWebM() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let ffprobe = try #require(MediaDownloadRuntime.findFFprobe(), "REAL_FFMPEG=1 needs an installed ffprobe")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("F962-real-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let webm = folder.appendingPathComponent("recording.webm")
    try await makeOpusWebM(at: webm, seconds: 7, ffmpeg: ffmpeg)
    try #require(DecodedAudio.declaredDuration(of: webm) == nil, "fixture: AVAudioFile read the WebM, so ffprobe is never consulted for it")

    let measured = try #require(await InterruptedLinkImportExtraction.measureDownload(webm, ffprobe: ffprobe))
    #expect(abs(measured - 7) <= InterruptedLinkImportExtraction.lengthTolerance, "\(measured)")

    let notMedia = folder.appendingPathComponent("recording.bin")
    try Data(repeating: 0x1A, count: 4_096).write(to: notMedia)
    #expect(await InterruptedLinkImportExtraction.measureDownload(notMedia, ffprobe: ffprobe) == nil)
    #expect(await InterruptedLinkImportExtraction.measureDownload(webm, ffprobe: nil) == nil)
}

@Test("ffprobe's answer counts only when it is one clean duration: a bitrate estimate, or any other message beside it, measures nothing (F962)")
func aProbedDurationCountsOnlyWhenItIsClean() {
    // A container with no Duration (a WebM or MKA written to a pipe) whose codec carries a bitrate is
    // measured by libavformat from size ÷ bitrate, and said so only at warning level. A guess can be
    // short as easily as long, and a short one would let Shrink remove a download holding more audio
    // than the recording, so any line beside the number is a reason to measure nothing.
    let estimate = "[matroska,webm @ 0x7845018000] Estimating duration from bitrate, this may be inaccurate\n20.393000\n"
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: estimate) == nil)
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: "[opus @ 0x1] Some other warning\n7.008000\n") == nil)
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: "7.008000\n7.008000\n") == nil)
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: "7.008000\n") == 7.008)
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: "N/A\n") == nil)
    #expect(InterruptedLinkImportExtraction.probedDuration(fromOutput: "") == nil)
    // The real tool is asked to say when it guesses.
    let arguments = MediaDownloadArguments.probeDuration(input: "/x/recording.mka")
    let level = arguments.firstIndex(of: "-v").map { arguments[arguments.index(after: $0)] }
    #expect(level == "warning", "\(arguments)")
}

@Test(
    "The installed ffprobe's bitrate guess for an MP3 in Matroska written to a pipe measures nothing, so Shrink keeps that download (F962)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFprobeBitrateGuessMeasuresNothing() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let ffprobe = try #require(MediaDownloadRuntime.findFFprobe(), "REAL_FFMPEG=1 needs an installed ffprobe")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("F962-guess-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let piped = folder.appendingPathComponent("recording.mka")
    // Written to a pipe, so the muxer cannot go back and write the Segment's Duration (the review's file).
    let made = try await ProcessGroupRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "\"$0\" -nostdin -loglevel error -f lavfi -i sine=frequency=440:duration=20 -c:a libmp3lame -b:a 128k -f matroska - > \"$1\"",
                    ffmpeg.path, piped.path],
        environment: MediaDownloadClient.makeEnvironment(),
        stallTimeout: 0
    )
    try #require(made.exitStatus == 0, "could not make the piped MKA: \(made.output)")
    try #require(DecodedAudio.declaredDuration(of: piped) == nil, "fixture: AVAudioFile read the MKA, so ffprobe is never consulted for it")

    #expect(await InterruptedLinkImportExtraction.measureDownload(piped, ffprobe: ffprobe) == nil,
            "a length ffprobe estimated from the bitrate was taken as measured")
}
