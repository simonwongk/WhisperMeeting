import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F941 — a link import's `recording.wav` is 16 kHz mono 16-bit PCM (yt-dlp's `-ar 16000 -ac 1
// -sample_fmt s16`), which is exactly the format Shrink's first step writes, and `afconvert -c 1 --mix`
// refuses an input already in its output format ("Couldn't set audio converter property (-50)"). So the
// Shrink button was offered for every link import and failed after the user confirmed it, saying a
// healthy recording could not be decoded. Driven through the calls the Shrink button makes, with the real
// encoder and decoder. Measured on macOS 27; the macos-15 runner may never have refused, so these assert
// that Shrink succeeds, which holds on both.

/// A 16 kHz mono tone, as a link import's WAV and its download hold it.
private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
}

/// A 16 kHz mono 16-bit WAV, the shape `WAVWriter` writes and the link import's extraction makes.
private func linkImportWAV(seconds: Double) -> Data {
    WAVWriter.wavData(from: tone(seconds: seconds), sampleRate: 16_000)
}

/// A link import in a temp library: `recording.wav` at 16 kHz mono, its `source.json`, and whatever
/// `extra` writes beside them.
@MainActor
private struct LinkImportFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    init(seconds: Double, extra: (URL) throws -> Void = { _ in }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F941-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try linkImportWAV(seconds: seconds).write(to: folder.appendingPathComponent("recording.wav"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
        try extra(folder)
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Conference talk", duration: seconds,
            recordingPath: "Recordings/\(id.uuidString)/recording.wav",
            status: .completed, transcriptText: "Hi."))
        // The free-space figure is the host's; these tests are about what is kept.
        model.availableBytesForShrink = { _ in .max }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A link import's 16 kHz mono WAV is shrunk, not refused as undecodable (F941)")
@MainActor
func shrinkCompressesASixteenKilohertzMonoLinkImport() async throws {
    let f = try LinkImportFixture(seconds: 20)
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    #expect(f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id))) == nil,
            "the button is offered, so the confirmed run has to succeed")

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk “Conference talk”"), "\(alert)")
    #expect(!alert.contains("unsupported file format"), "\(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav"), "\(alert)")
    #expect(f.exists(MediaSource.sidecarFilename), "the link is kept")
    #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/recording.m4a") == true)
    // The copy is the recording, not a silent stand-in of the right length.
    let copy = try DecodedAudio.fullyDecoded(of: f.folder.appendingPathComponent("recording.m4a"))
    #expect(abs(copy.duration - 20) < 0.5)
    #expect(copy.level > 0.15, "\(copy.level)")
}

@Test("A link import with a download no longer than its WAV is shrunk, and the download removed (F941, F911)")
@MainActor
func shrinkCompressesALinkImportBesideACoveredDownload() async throws {
    // F911's end-to-end case, which the 16 kHz refusal hid: the download beside the WAV holds no more
    // audio, so it is a leftover of the import and goes with the original.
    let f = try LinkImportFixture(seconds: 20) { folder in
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("recording.mp4"), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let samples = tone(seconds: 20)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        try file.write(from: buffer)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk “Conference talk”"), "\(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav") && !f.exists("recording.mp4"), "\(alert)")
}
