import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F947 — since F911, Shrink keeps a link import's download unless it can show the recording holds no
// less audio. AVFoundation cannot measure a WebM, so a meeting whose download is a WebM was never
// shrunk — and after recovery converts a WebM download (F453, F911) the folder holds exactly that:
// the finished WAV, a full conversion of the download, and the WebM beside it. Recovery now records,
// when its own conversion of the whole download succeeds, how long that conversion is
// (`InterruptedLinkImportExtraction.recordConversion`), and Shrink reads the record as the download's
// length when nothing else can measure it.
//
// The conversion is stubbed to write what the real one writes, a 16 kHz mono 16-bit WAV, so the shrink
// below runs end to end on the real shape (Shrink's encode takes that input since F941).

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

/// Bytes AVFoundation cannot open, standing for YouTube's usual Opus in WebM (format 251).
private let webmDownload = Data(repeating: 0x1A, count: 4_096)

/// A link import interrupted mid-extraction, recovered by `performStartupRecovery` with a conversion
/// that finishes: the meeting is the converted WAV, and the WebM stays beside it.
@MainActor
private func recoveredWebMImport(_ label: String) async throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F947-\(label)-\(UUID().uuidString)")
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
    model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
    model.crashReportsSince = { _ in [] }
    model.finishInterruptedLinkImportExtraction = { download in
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: tone(seconds: 6, rate: 16_000), sampleRate: 16_000).write(to: finished)
        return finished
    }
    // The free-space figure is the host's; these tests are about what is kept.
    model.availableBytesForShrink = { _ in .max }
    // F1004: Shrink decodes the WebM with the installed ffmpeg to check its channels; here it decodes to what
    // the conversion holds, one channel, which has nothing to cancel against.
    model.decodeUnreadableForShrink = { _, output in
        try WAVWriter.wavData(from: tone(seconds: 6, rate: 16_000), sampleRate: 16_000).write(to: output)
    }
    await model.performStartupRecovery()
    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    try #require(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    return (root, model, id, folder)
}

@MainActor
@Test("A link import whose WebM download recovery converted can be shrunk, and Shrink removes the WebM (F947)")
func aRecoveredWebMImportShrinks() async throws {
    let (root, model, id, folder) = try await recoveredWebMImport("shrinks")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.refreshStorage(ids: [id])
    let meeting = try #require(model.store.meeting(id: id))
    #expect(model.shrinkUnavailability(for: meeting) == nil,
            "\(String(describing: model.shrinkUnavailability(for: meeting)?.message))")

    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let shrunk = try #require(model.store.meeting(id: id))
    #expect(shrunk.recordingPath.hasSuffix("recording.m4a"), "\(shrunk.recordingPath); \(model.alertMessage ?? "")")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path), "the WebM was kept")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MediaSource.sidecarFilename).path))
}

@MainActor
@Test("Without recovery's record, or with one for another file, a WebM beside the recording is still kept (F947)")
func aWebMWithoutAMatchingRecordIsKept() async throws {
    let (root, model, id, folder) = try await recoveredWebMImport("kept")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename)
    let webm = folder.appendingPathComponent("recording.webm")
    let unmeasured = MeetingStoragePlan.Unavailability.otherRecordingMayHoldMore(name: "recording.webm", seconds: nil)
    #expect(FileManager.default.fileExists(atPath: record.path), "recovery recorded nothing about its conversion")

    // A download whose size has changed is not the one that was converted.
    let handle = try FileHandle(forWritingTo: webm)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0x00]))
    try handle.close()
    await model.refreshStorage(ids: [id])
    #expect(model.shrinkUnavailability(for: try #require(model.store.meeting(id: id))) == unmeasured)

    // No record at all: a folder recovered before F947, or one whose record could not be written.
    try? FileManager.default.removeItem(at: record)
    await model.refreshStorage(ids: [id])
    #expect(model.shrinkUnavailability(for: try #require(model.store.meeting(id: id))) == unmeasured)
}
