import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// Hand-built `CMSampleBuffer`s for driving the real `FloatTrackWriter.append` (F856, F875).
///
/// ScreenCaptureKit hands the writer whatever the device's native format is (`SCStream.h:26`), so the
/// tests need every shape it might be: float32 or Int16, deinterleaved or interleaved, with or
/// without a channel layout. Each buffer carries a 440 Hz tone in ONE channel and silence in the
/// rest, so only an average of every channel reads `amplitude / channels`.
enum CapturedSampleBuffer {
    static let rate: Double = 48_000

    static func make(
        channels: UInt32,
        frames: Int,
        startFrame: Int = 0,
        float: Bool = true,
        interleaved: Bool = false,
        layoutTag: AudioChannelLayoutTag? = nil,
        toneChannel: Int? = nil,
        amplitude: Float = 0.5
    ) throws -> CMSampleBuffer {
        let bytesPerSample = float ? 4 : 2
        var flags: AudioFormatFlags = (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(interleaved ? bytesPerSample * Int(channels) : bytesPerSample)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: UInt32(bytesPerSample * 8), mReserved: 0
        )
        var description: CMAudioFormatDescription?
        var layout = AudioChannelLayout(
            mChannelLayoutTag: layoutTag ?? 0, mChannelBitmap: [], mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        let created = layoutTag == nil
            ? CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            : CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &description)
        try #require(created == noErr, "CMAudioFormatDescriptionCreate: \(created)")
        let format = try #require(description)

        var sampleBuffer: CMSampleBuffer?
        let made = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        try #require(made == noErr, "CMAudioSampleBufferCreateWithPacketDescriptions: \(made)")
        let buffer = try #require(sampleBuffer)

        // One `AudioBuffer` per channel when deinterleaved, one holding every channel when interleaved.
        // `CMSampleBufferSetDataBufferFromAudioBufferList` copies the data into a new block buffer
        // (`CMSampleBuffer.h`: "Buffer list whose data will be copied into the new CMBlockBuffer").
        let channelCount = Int(channels)
        let tone = toneChannel ?? channelCount - 1
        let bufferCount = interleaved ? 1 : channelCount
        let samplesPerBuffer = interleaved ? frames * channelCount : frames
        let byteCount = samplesPerBuffer * bytesPerSample
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }
        var copies: [UnsafeMutableRawPointer] = []
        defer { copies.forEach { $0.deallocate() } }
        for index in 0..<bufferCount {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            memset(raw, 0, byteCount)
            copies.append(raw)
            list[index] = AudioBuffer(
                mNumberChannels: interleaved ? channels : 1, mDataByteSize: UInt32(byteCount), mData: raw
            )
        }
        for frame in 0..<frames {
            let value = Double(amplitude) * sin(2 * Double.pi * 440 * Double(startFrame + frame) / rate)
            let (bufferIndex, offset) = interleaved ? (0, frame * channelCount + tone) : (tone, frame)
            if float {
                copies[bufferIndex].assumingMemoryBound(to: Float.self)[offset] = Float(value)
            } else {
                copies[bufferIndex].assumingMemoryBound(to: Int16.self)[offset] = Int16(value * 32_767)
            }
        }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: list.unsafePointer
        )
        try #require(status == noErr, "CMSampleBufferSetDataBufferFromAudioBufferList: \(status)")
        return buffer
    }

    /// A fresh track location in its own temporary folder; remove `deletingLastPathComponent()` after.
    static func temporaryTrackURL(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("microphone-audio.f32")
    }

    /// The float32 samples a finished track holds on disk.
    static func samples(of track: FloatTrack) throws -> [Float] {
        let data = try Data(contentsOf: track.url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
