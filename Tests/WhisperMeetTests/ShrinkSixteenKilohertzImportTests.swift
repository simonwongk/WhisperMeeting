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

// Review of F941: a WAV's or a CAF's header says it is mono, but a recording already in the output's
// format can sit in another container — an AIFF-C holding little-endian samples (what ffmpeg writes for
// `pcm_s16le -f aiff`), or a movie holding raw 16 kHz mono PCM — and `--mix` still made afconvert refuse it,
// so Qwen could not transcribe such an import and Shrink failed on it. Import accepts any audio or movie.

/// A 16 kHz mono 16-bit AIFF-C holding little-endian samples ('sowt'), byte for byte the header ffmpeg
/// writes for `-c:a pcm_s16le -f aiff`. Built by hand: afconvert refuses to write one ('fmt?'), and the
/// `.aifc` AVAudioFile writes when asked for little-endian samples converted with `--mix`, so showed nothing.
private func sowtAIFC(_ samples: [Float]) -> Data {
    var data = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("FORM".utf8)); u32(4 + 12 + 32 + 16 + bytes)
    data.append(contentsOf: Array("AIFC".utf8))
    data.append(contentsOf: Array("FVER".utf8)); u32(4); u32(0xA280_5140)
    data.append(contentsOf: Array("COMM".utf8)); u32(24)
    u16(1); u32(UInt32(samples.count)); u16(16)
    // 16000 as an 80-bit IEEE extended: exponent 16383 + 13, mantissa 16000 << 50.
    data.append(contentsOf: [0x40, 0x0C, 0xFA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] as [UInt8])
    data.append(contentsOf: Array("sowt".utf8)); u16(0)
    data.append(contentsOf: Array("SSND".utf8)); u32(8 + bytes); u32(0); u32(0)
    let pcm = samples.map { Int16(Swift.max(-1, Swift.min(1, $0)) * 32_767).littleEndian }
    pcm.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// A QuickTime movie whose one track is 16 kHz mono 16-bit little-endian PCM, uncompressed.
private func sixteenKilohertzMonoPCMMovie(_ samples: [Float], to url: URL) async throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                   AVLinearPCMIsNonInterleaved: false]
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    let pcm = samples.map { Int16(Swift.max(-1, Swift.min(1, $0)) * 32_767) }
    let buffer = try fixtureSampleBuffer(pcm, channels: 1, rate: 16_000, startFrame: 0)
    let deadline = Date().addingTimeInterval(30)
    while !input.isReadyForMoreMediaData {
        try #require(Date() < deadline, "the writer stalled")
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try #require(input.append(buffer), "\(String(describing: writer.error))")
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
}

@Test("A 16 kHz mono recording in an AIFF-C or a movie transcodes too, read from its format not its header (F941 review)")
func transcodeAcceptsSixteenKilohertzMonoInOtherContainers() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("F941-containers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["recording.aiff", "recording.mov"] {
        let input = dir.appendingPathComponent(name)
        if name.hasSuffix(".aiff") {
            try sowtAIFC(tone(seconds: 2)).write(to: input)
        } else {
            try await sixteenKilohertzMonoPCMMovie(tone(seconds: 2), to: input)
        }
        let output = dir.appendingPathComponent("\(name).wav")

        do {
            try AudioTranscoder.transcodeToWAV(input: input, output: output)
        } catch {
            Issue.record("\(name): \(error)")
            continue
        }

        let decoded = try #require(fixtureDecode(output).channels.first)
        #expect(abs(fixtureToneAmplitude(decoded, rate: 16_000, frequency: 440) - 0.3) < 0.01, "\(name)")
    }
}
