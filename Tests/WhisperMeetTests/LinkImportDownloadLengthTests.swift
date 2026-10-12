import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F948 — startup recovery measured an interrupted link import's download with
// `AppModel.loadDuration(of:)`, which is `AVURLAsset` with no options, so its duration may be an
// estimate; Shrink reads the same file with AVAudioFile (`DecodedAudio.declaredDuration`). For a VBR
// MP3 without a Xing/Info header the estimate is short. So a WAV ffmpeg finished on SIGTERM (F911)
// that was shorter than the download but longer than the estimate was indexed as the whole import,
// with no caveat, and a meeting made from such a download took the estimate as its duration.
//
// The fixture is synthetic: 2 s of white noise then 18 s of a quiet tone, VBR MP3 with no length
// header, made with ffmpeg 8.1.2 (`libmp3lame -q:a 0 -write_xing 0`, 44.1 kHz mono, noise seed 948;
// the recipe is in the lane's `gates/f948-make-fixture.sh`). The loud start gives its first frames a
// bitrate far above the file's average, which is what a bitrate-based estimate extrapolates from.
// Measured on this Mac (macOS 27): AVURLAsset 16.379 s, AVURLAsset with precise timing 20.036 s,
// AVAudioFile 20.036 s. The assertions below hold whatever AVURLAsset reads on the host, since the
// expected length is asked of the reader Shrink uses.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/vbr-mp3-no-length-header-20s.mp3")

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

/// `Recordings/<id>/` holding a link import's `source.json`, the MP3 download, and `wav` as `recording.wav`.
private func makeInterruptedImport(in root: URL, wav: Data) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind,
        pageURL: "https://example.com/talk.mp3",
        host: "example.com",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("recording.mp3"))
    try wav.write(to: folder.appendingPathComponent("recording.wav"))
    return (id, folder)
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F948-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func makeModel(root: URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    // An MP3 is measurable, so nothing is converted; a conversion here would be a wrong turn.
    model.finishInterruptedLinkImportExtraction = { _ in throw MediaDownloadError.extractionFailed }
    return model
}

@MainActor
@Test("A shorter finished WAV beside a VBR MP3 with no length header is recovered from the download (F948)")
func aShorterWAVLosesToAnMP3WithNoLengthHeader() async throws {
    let fullLength = try #require(DecodedAudio.declaredDuration(of: fixture), "AVAudioFile cannot read the fixture")
    try #require(fullLength > 19.5, "the fixture reads \(fullLength) s")
    let root = try makeRoot("sigterm")
    defer { try? FileManager.default.removeItem(at: root) }
    // 18 s: shorter than the download by more than the half-second tolerance, and longer than the
    // 16.4 s AVURLAsset estimates for it on this Mac.
    let (id, folder) = try makeInterruptedImport(in: root, wav: WAVWriter.wavData(from: tone(seconds: 18), sampleRate: 16_000))
    let download = try Data(contentsOf: folder.appendingPathComponent("recording.mp3"))
    let model = makeModel(root: root)

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.recordingPath.hasSuffix("recording.mp3"), "the 18 s WAV was kept as the whole import: \(meeting.recordingPath)")
    #expect(abs(meeting.duration - fullLength) < 0.01, "the meeting is \(meeting.duration) s of a \(fullLength) s download")
    #expect(try Data(contentsOf: folder.appendingPathComponent("recording.mp3")) == download, "the download changed")
}

@MainActor
@Test("A meeting made from a VBR MP3 with no length header records its full length (F948)")
func aMeetingFromAnMP3WithNoLengthHeaderHasItsFullLength() async throws {
    // ffmpeg never finished the WAV, so the download is the recording (F453) — and its length is the
    // meeting's.
    let fullLength = try #require(DecodedAudio.declaredDuration(of: fixture), "AVAudioFile cannot read the fixture")
    let root = try makeRoot("placeholder")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, _) = try makeInterruptedImport(in: root, wav: try unfinishedWAV(seconds: 2))
    let model = makeModel(root: root)

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.mp3"), "indexed against \(meeting.recordingPath)")
    #expect(abs(meeting.duration - fullLength) < 0.01, "the meeting records \(meeting.duration) s of a \(fullLength) s download")
    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
}
