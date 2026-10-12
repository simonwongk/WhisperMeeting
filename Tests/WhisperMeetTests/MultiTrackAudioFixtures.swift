import AVFoundation
import Foundation
import Testing

// Synthetic recordings with several audio tracks, or with more than two channels, for F942 and F953.
// Every tone is a pure sine whose amplitude a decoder can be asked about, so a test can say which
// track or channel reached a file and at what level. Written with AVFoundation, which ships with
// macOS (the CI runner included); no user recording is read.

/// One audio track to write: one tone per channel, `(frequency, amplitude)`, presented from `startSeconds`.
struct FixtureTrack {
    var channels: [(frequency: Double, amplitude: Double)]
    var seconds: Double
    var startSeconds: Double = 0
    /// Silence outside `[from, to)` seconds of the track's own time, for talkers who take turns.
    var audibleFrom: Double = 0
    var audibleTo: Double = .infinity
}

/// A sine at `frequency` of `amplitude`, silent outside `[from, to)`.
func fixtureTone(frequency: Double, amplitude: Double, seconds: Double, rate: Double = 48_000,
                 from: Double = 0, to: Double = .infinity) -> [Float] {
    (0..<Int(seconds * rate)).map { n in
        let t = Double(n) / rate
        return t < from || t >= to ? 0 : Float(amplitude * sin(2 * Double.pi * frequency * t))
    }
}

/// Writes a QuickTime or MPEG-4 file with one AAC track per `FixtureTrack`. With `alternates`, every
/// track is put in one alternate group, the way a movie carries its languages: only the first is
/// enabled, and AVFoundation reports the group.
func writeFixtureTracks(to url: URL, _ tracks: [FixtureTrack], alternates: Bool = false) async throws {
    let rate = 48_000.0
    let type: AVFileType = url.pathExtension == "mov" ? .mov : (url.pathExtension == "m4a" ? .m4a : .mp4)
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    var inputs: [AVAssetWriterInput] = []
    for track in tracks {
        let count = track.channels.count
        // 128 kbps a channel, so each file is large enough beside Shrink's 32 kbps output that the
        // "nothing to gain" rule never decides a test about tracks.
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: count, AVEncoderBitRateKey: 128_000 * count]
        if count == 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        try #require(writer.canAdd(input))
        writer.add(input)
        inputs.append(input)
    }
    if alternates {
        let group = AVAssetWriterInputGroup(inputs: inputs, defaultInput: inputs.first)
        try #require(writer.canAdd(group))
        writer.add(group)
    }
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    let samples: [[[Float]]] = tracks.map { track in
        track.channels.map {
            fixtureTone(frequency: $0.frequency, amplitude: $0.amplitude, seconds: track.seconds, rate: rate,
                        from: track.audibleFrom, to: track.audibleTo)
        }
    }
    let chunk = 4_800
    var next = [Int](repeating: 0, count: inputs.count)
    var finished = [Bool](repeating: false, count: inputs.count)
    let deadline = Date().addingTimeInterval(30)
    // Each turn feeds every input that is ready. Waiting on one input while the writer wants another
    // to catch up first never ends, so no input is waited on alone; a stall fails on the 30 s cap.
    while finished.contains(false) {
        var progressed = false
        for (index, input) in inputs.enumerated() where !finished[index] {
            let total = samples[index][0].count
            if next[index] >= total {
                input.markAsFinished()
                finished[index] = true
                progressed = true
                continue
            }
            guard input.isReadyForMoreMediaData else { continue }
            let start = next[index], count = min(chunk, total - start), channels = samples[index].count
            var interleaved = [Int16](repeating: 0, count: count * channels)
            for frame in 0..<count {
                for channel in 0..<channels {
                    interleaved[frame * channels + channel] = Int16(clampedFixtureSample: samples[index][channel][start + frame])
                }
            }
            let startFrame = Int((tracks[index].startSeconds * rate).rounded()) + start
            try #require(input.append(try fixtureSampleBuffer(interleaved, channels: channels, rate: rate, startFrame: startFrame)),
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

private extension Int16 {
    init(clampedFixtureSample sample: Float) {
        self = Int16(Swift.max(-1, Swift.min(1, sample)) * 32_767)
    }
}

/// Interleaved 16-bit PCM as a `CMSampleBuffer` an `AVAssetWriterInput` encodes.
private func fixtureSampleBuffer(_ samples: [Int16], channels: Int, rate: Double, startFrame: Int) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
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
        sampleCount: samples.count / channels,
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(rate)),
        packetDescriptions: nil, sampleBufferOut: &buffer) == noErr)
    return try #require(buffer)
}

/// A 16-bit WAV at 48 kHz holding one channel per array. With `mask` nil it is plain `WAVE_FORMAT_PCM`
/// with no channel layout, the shape a field or podcast recorder's "poly" WAV often has; with a mask it
/// is `WAVE_FORMAT_EXTENSIBLE`, where 0 means no positions and 0x3F is 5.1 (FL FR FC LFE BL BR).
func fixturePolyWAV(_ channels: [[Float]], mask: UInt32? = nil) -> Data {
    let count = channels.count, frames = channels.map(\.count).min() ?? 0
    var data = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = UInt32(frames * count * 2)
    let formatSize: UInt32 = mask == nil ? 16 : 40
    data.append(contentsOf: Array("RIFF".utf8)); u32(4 + 8 + formatSize + 8 + byteCount)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(formatSize)
    u16(mask == nil ? 1 : 0xFFFE); u16(UInt16(count)); u32(48_000); u32(UInt32(48_000 * count * 2))
    u16(UInt16(count * 2)); u16(16)
    if let mask {
        u16(22); u16(16); u32(mask)
        // KSDATAFORMAT_SUBTYPE_PCM
        let pcm: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        data.append(contentsOf: pcm)
    }
    data.append(contentsOf: Array("data".utf8)); u32(byteCount)
    var samples = [Int16](repeating: 0, count: frames * count)
    for frame in 0..<frames {
        for channel in 0..<count { samples[frame * count + channel] = Int16(clampedFixtureSample: channels[channel][frame]) }
    }
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// What a file holds, decoded by AVAudioFile: its rate, its channels' samples, deinterleaved. AVAudioFile
/// reads a container's first audio track only, as afconvert and Whisper's ffmpeg decode do (F801's
/// probe), so for a several-track file this is what the engines heard before F942.
func fixtureDecode(_ url: URL) throws -> (rate: Double, channels: [[Float]]) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let frames = Int(buffer.frameLength)
    let channels: [[Float]] = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    return (format.sampleRate, channels)
}

/// The amplitude of a sine at `frequency` in `samples`, over `[from, to)` seconds: 0.2 for a tone
/// written at 0.2, 0 for one that is absent.
func fixtureToneAmplitude(_ samples: [Float], rate: Double, frequency: Double,
                          from: Double = 0, to: Double = .infinity) -> Double {
    let first = Swift.max(0, Int(from * rate)), last = Swift.min(samples.count, to.isFinite ? Int(to * rate) : samples.count)
    guard last > first else { return 0 }
    var real = 0.0, imaginary = 0.0
    let step = 2 * Double.pi * frequency / rate
    for n in first..<last {
        real += Double(samples[n]) * cos(step * Double(n))
        imaginary -= Double(samples[n]) * sin(step * Double(n))
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(last - first)
}
