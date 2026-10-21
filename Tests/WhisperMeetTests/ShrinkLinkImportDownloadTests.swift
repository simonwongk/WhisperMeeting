import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F911 (Shrink) — a link import recovered from the shorter WAV ffmpeg finished on SIGTERM still has
// its complete download beside it, as a `recording.<ext>`. Shrink removes every other
// `recording.<ext>` as a leftover of the import, and the output takes the name `recording.m4a` — so
// once its encode succeeded, shrinking that meeting deleted the download, or, when the download was
// itself `recording.m4a` (YouTube's format 140), overwrote it with the encode. Either way the only
// full copy was gone. Shrink now refuses unless every other `recording.<ext>` is shown to hold no
// more audio than the recording. Driven through the calls the Shrink button makes, with the real
// encoder and decoder (afconvert and AVFoundation ship with macOS, the CI runner included).
//
// The recordings here are 48 kHz WAVs, not the 16 kHz mono WAV a link import actually holds: when
// these were written, Shrink's first encode step (`afconvert … -c 1 --mix`) refused a 16 kHz mono PCM
// input outright ("Couldn't set audio converter property (-50)"), so with a real import's WAV the
// encode failed before anything was deleted, which hid the deletion these tests are about. That
// refusal was F941; since its fix the real shape shrinks, and `ShrinkSixteenKilohertzImportTests`
// drives it beside a download no longer than its WAV.

/// A tone at `rate`: 16 kHz for a download, 48 kHz for the recording Shrink encodes.
private func tone(seconds: Double, rate: Double = 16_000) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
}

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

/// A recovered link import in a temp library: indexed against `recording.wav`, with the download
/// `write` puts beside it and the import's `source.json`.
@MainActor
private struct DownloadFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    init(wavSeconds: Double, download name: String, _ write: (URL) throws -> Void) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F911-shrink-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAVWriter.wavData(from: tone(seconds: wavSeconds, rate: 48_000), sampleRate: 48_000)
            .write(to: folder.appendingPathComponent("recording.wav"))
        try write(folder.appendingPathComponent(name))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
        model.store.upsert(MeetingRecord(
            id: id, title: "Conference talk", duration: wavSeconds,
            recordingPath: "Recordings/\(id.uuidString)/recording.wav",
            status: .completed, transcriptText: "Hi.",
            recoverySource: RecoveredRecording.Source.importedRecording.rawValue))
        // The free-space figure is the host's; these tests are about what is kept.
        model.availableBytesForShrink = { _ in .max }
    }

    func bytes(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("Shrink keeps a download that runs longer than the recording, and says why (F911)")
@MainActor
func shrinkKeepsALongerDownload() async throws {
    // The download is recording.m4a: Shrink's own output name, so the encode would have replaced it.
    let f = try DownloadFixture(wavSeconds: 3, download: "recording.m4a") { try writeM4A(seconds: 6, to: $0) }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let download = try f.bytes("recording.m4a")
    let wav = try f.bytes("recording.wav")

    await f.shrink()

    #expect(try f.bytes("recording.m4a") == download, "the complete download was replaced or removed")
    #expect(try f.bytes("recording.wav") == wav)
    #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/recording.wav") == true)
    // Refused when it is asked for, before anything runs: the button shows the same reason.
    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("can't be shrunk now"), "\(alert)")
    #expect(alert.contains("recording.m4a") && alert.contains("longer than this recording"), "says which file and why: \(alert)")
}

@Test("Shrink keeps a download whose length macOS cannot read (F911)")
@MainActor
func shrinkKeepsADownloadItCannotMeasure() async throws {
    let webm = Data("a complete WebM download macOS cannot open".utf8)
    let f = try DownloadFixture(wavSeconds: 3, download: "recording.webm") { try webm.write(to: $0) }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    #expect(try f.bytes("recording.webm") == webm, "the complete download was removed")
    #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/recording.wav") == true)
    let meeting = try #require(f.model.store.meeting(id: f.id))
    #expect(f.model.shrinkUnavailability(for: meeting) == .otherRecordingMayHoldMore(name: "recording.webm", seconds: nil))
    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("can't be shrunk now") && alert.contains("recording.webm"), "\(alert)")
    #expect(alert.contains("can't be read"), "says why: \(alert)")
}

@Test("A download no longer than the recording is still removed by Shrink, as before (F911 control)")
@MainActor
func shrinkStillShrinksBesideADownloadNoLonger() async throws {
    let f = try DownloadFixture(wavSeconds: 6, download: "recording.m4a") { try writeM4A(seconds: 6, to: $0) }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/recording.m4a") == true)
    #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("recording.wav").path))
}
