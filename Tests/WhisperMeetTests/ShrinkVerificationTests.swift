import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F801 — Shrink deletes the original permanently, and its only check on the compressed copy was its
// length. An encode that came out silent has the right length and passed; and `afconvert` decodes
// only the first audio track of a container, so an import with two tracks (a call recorded with
// one track per side) kept track 1 and lost the rest, with nothing said. Now the copy's level must
// match the original's, and a recording with more than one audio track is not shrunk.
// Driven through the app-level calls the Shrink button makes, over temp libraries of synthetic
// imports. The real encoder and decoder run here: afconvert and AVFoundation ship with macOS, the
// CI runner included.

/// Records that a `@Sendable` seam ran.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func set() { lock.lock(); called = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return called }
}

/// A 48 kHz mono tone, shaped like what a capture or a plain import holds.
private func toneSamples(seconds: Double, amplitude: Double = 0.3, frequency: Double = 220) -> [Float] {
    (0..<Int(seconds * 48_000)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
}

/// One imported meeting in a temp library: `Recordings/<id>/recording.<ext>`, as `importOne` lays it out.
@MainActor
private struct ImportFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL
    let recording: URL

    init(recordingExtension ext: String, duration: TimeInterval, write: (URL) async throws -> Void) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F801-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recording = folder.appendingPathComponent("recording.\(ext)")
        try await write(recording)
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Client call", duration: duration,
            recordingPath: "Recordings/\(id.uuidString)/recording.\(ext)",
            status: .completed, transcriptText: "Hi."))
        // The free-space figure is the host's; these tests are about what is kept.
        model.availableBytesForShrink = { _ in .max }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func hiddenTemps() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".shrink-") }
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A compressed copy that came out silent is discarded, and the original is kept (F801)")
@MainActor
func shrinkRefusesASilentEncode() async throws {
    let f = try await ImportFixture(recordingExtension: "wav", duration: 6) { url in
        try WAVWriter.wavData(from: toneSamples(seconds: 6), sampleRate: 48_000).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    // A real AAC file of the right length, holding nothing: the encode every check but the
    // length's would see through. Made by the real encoder from six seconds of silence.
    let silence = f.root.appendingPathComponent("silence.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0, count: 6 * 48_000), sampleRate: 48_000).write(to: silence)
    f.model.encodeForShrink = { _, output, workingWAV in
        try AudioCompressor.compressSpeech(input: silence, output: output, workingWAV: workingWAV)
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    #expect(f.exists("recording.wav"), "the original is the only copy of the audio")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty)
    #expect(f.model.store.meeting(id: f.id)?.recordingPath.hasSuffix("/recording.wav") == true)
    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("silent or much quieter"), "says why, in Shrink's own words: \(alert)")
}

@Test("A faithful encode keeps its level and is shrunk as before (F801 control)")
@MainActor
func shrinkAcceptsAFaithfulEncode() async throws {
    let f = try await ImportFixture(recordingExtension: "wav", duration: 6) { url in
        try WAVWriter.wavData(from: toneSamples(seconds: 6), sampleRate: 48_000).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav"), "\(alert)")
}

@Test("An import with two audio tracks is not shrunk, and says what would be lost (F801)")
@MainActor
func shrinkRefusesAMultiTrackImport() async throws {
    // A call recorded with one track per side: the quiet side on track 1, the loud one on track 2.
    let f = try await ImportFixture(recordingExtension: "mov", duration: 3) { url in
        try await writeAudioTracks(to: url, tracks: [(300, 0.05), (800, 0.4)], seconds: 3)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    let original = try Data(contentsOf: f.recording)

    await f.model.refreshStorage(ids: [f.id])
    let reason = f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id)))
    #expect(reason?.message.contains("2 audio tracks") == true, "\(String(describing: reason))")
    #expect(reason == .multipleAudioTracks(count: 2), "counted from the file, by AVFoundation")
    await f.shrink()

    #expect(!encoded.value, "refused before anything is encoded")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("2 audio tracks"), "\(alert)")
}

@Test("An import with one audio track in a movie container can still be shrunk (F801 control)")
@MainActor
func shrinkAcceptsASingleTrackMovie() async throws {
    let f = try await ImportFixture(recordingExtension: "mov", duration: 3) { url in
        try await writeAudioTracks(to: url, tracks: [(800, 0.4)], seconds: 3)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.model.refreshStorage(ids: [f.id])

    let reason = f.model.shrinkUnavailability(for: try #require(f.model.store.meeting(id: f.id)))
    #expect(reason == nil, "\(String(describing: reason))")
}

// MARK: - A container with several audio tracks, written the way a recorder writes one

/// Writes a QuickTime or MPEG-4 file with one AAC audio track per `(frequency, amplitude)` tone.
/// Probed on this Mac before the test was written: AVURLAsset reports one audio track per input,
/// and both AVAudioFile and afconvert read only the first.
private func writeAudioTracks(
    to url: URL, tracks: [(frequency: Double, amplitude: Double)], seconds: Double
) async throws {
    let rate = 48_000.0
    let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
    // 128 kbps, so even one track is large enough beside Shrink's 32 kbps output to be worth shrinking
    // (the "nothing to gain" rule), and a refusal here can only be about the tracks.
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
    let inputs = tracks.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: settings) }
    for input in inputs {
        input.expectsMediaDataInRealTime = false
        try #require(writer.canAdd(input))
        writer.add(input)
    }
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    let total = Int(seconds * rate), chunk = 4_800
    var next = [Int](repeating: 0, count: inputs.count)
    var finished = [Bool](repeating: false, count: inputs.count)
    let deadline = Date().addingTimeInterval(30)
    // Each turn feeds every input that is ready. Waiting on one input while the writer wants another
    // to catch up first never ends, so no input is waited on alone; a stall fails on the 30 s cap.
    while finished.contains(false) {
        var progressed = false
        for (index, input) in inputs.enumerated() where !finished[index] {
            if next[index] >= total {
                input.markAsFinished()
                finished[index] = true
                progressed = true
                continue
            }
            guard input.isReadyForMoreMediaData else { continue }
            let start = next[index], count = min(chunk, total - start), tone = tracks[index]
            let samples = (0..<count).map { i -> Int16 in
                Int16(tone.amplitude * 32_767 * sin(2 * Double.pi * tone.frequency * Double(start + i) / rate))
            }
            try #require(input.append(try pcmSampleBuffer(samples, rate: rate, startFrame: start)),
                         "\(String(describing: writer.error))")
            next[index] = start + count
            progressed = true
        }
        if !progressed {
            try #require(writer.status == .writing && Date() < deadline,
                         "the writer stalled: \(String(describing: writer.error))")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
}

/// Mono 16-bit PCM samples as a `CMSampleBuffer` an `AVAssetWriterInput` encodes.
private func pcmSampleBuffer(_ samples: [Int16], rate: Double, startFrame: Int) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    let length = samples.count * 2
    var block: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr)
    let filled = try samples.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(
            with: try #require(raw.baseAddress), blockBuffer: try #require(block),
            offsetIntoDestination: 0, dataLength: length)
    }
    try #require(filled == noErr)
    var buffer: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format),
        sampleCount: samples.count,
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(rate)),
        packetDescriptions: nil, sampleBufferOut: &buffer) == noErr)
    return try #require(buffer)
}
