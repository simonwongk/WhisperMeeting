import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F856 — a captured buffer whose format description has more than 2 channels and NO channel layout.
//
// `FloatTrackWriter.append` built its input format with `AVAudioFormat(cmAudioFormatDescription:)`.
// `AVAudioFormat.h:149` says that initializer "fails (returns nil)" for an invalid description, but
// it is imported into Swift as non-optional, so the nil arrives as an object nothing checks. A
// format with more than 2 channels must carry a layout (`AVAudioFormat.h:203`: "Only formats with
// more than 2 channels are required to have channel layouts"), so a 4-channel description without
// one is exactly such an invalid description. Measured on this Mac before the fix (lane X's probe):
// `CMAudioFormatDescription 4ch layout=none -> objc nil=true`, then `channels=0`, then SIGSEGV — a
// crash no `catch` and no Objective-C exception bridge can intercept, in the middle of a recording.
// Meeting capture's microphone track arrives in "the selected microphone capture device's native
// format" (`SCStream.h:26`), so the description is whatever the device reports.
//
// These drive the real `FloatTrackWriter.append` with a real `CMSampleBuffer`, which F402 and F419
// could not: the writer was file-private. Its own `append` is what is under test here; the
// SCStream handler around it is unchanged and still not driven (F402's reachability note).

private let captureRate: Double = CapturedSampleBuffer.rate
private let toneAmplitude: Float = 0.5

/// A captured buffer as ScreenCaptureKit hands one over: float32, deinterleaved, `channels` wide,
/// a 440 Hz tone in the last channel and silence in the rest, and — unless `layoutTag` is given — a
/// format description with no channel layout at all. Built by the shared `CapturedSampleBuffer`.
private func capturedBuffer(
    channels: UInt32,
    frames: Int,
    startFrame: Int = 0,
    layoutTag: AudioChannelLayoutTag? = nil
) throws -> CMSampleBuffer {
    try CapturedSampleBuffer.make(
        channels: channels, frames: frames, startFrame: startFrame, layoutTag: layoutTag, amplitude: toneAmplitude
    )
}

private func temporaryTrackURL() throws -> URL {
    try CapturedSampleBuffer.temporaryTrackURL("F856")
}

private func samples(of track: FloatTrack) throws -> [Float] {
    try CapturedSampleBuffer.samples(of: track)
}

@Test("A 4-channel buffer with no channel layout is recorded, averaged, not a crash (F856)")
func fourChannelBufferWithoutALayoutIsRecorded() throws {
    let url = try temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try FloatTrackWriter(outputURL: url, targetSampleRate: captureRate)

    // Two consecutive buffers of 1,024 frames, the size ScreenCaptureKit hands over, so the second
    // also goes through the converter the first one built.
    let first = try capturedBuffer(channels: 4, frames: 1_024)
    let second = try capturedBuffer(channels: 4, frames: 1_024, startFrame: 1_024)
    try #require(first.formatDescription.flatMap { CMAudioFormatDescriptionGetChannelLayout($0, sizeOut: nil) } == nil,
                 "the fixture must carry no channel layout, which is the case under test")

    let level = try #require(try writer.append(first))
    _ = try #require(try writer.append(second))
    let track = try writer.finish()

    // Reads correctly: every captured frame is on disk once, and the tone carried only by channel 4
    // is there at a quarter of its amplitude — the average of four channels (F659).
    #expect(track.frameCount == 2_048)
    let recorded = try samples(of: track)
    #expect(recorded.count == 2_048)
    let peak = recorded.reduce(0) { max($0, abs($1)) }
    let expected = toneAmplitude / 4
    #expect(abs(peak - expected) < expected * 0.01, "peak \(peak), expected \(expected)")
    #expect(abs(level.peak - expected) < expected * 0.01, "the live meter reads the same mix: \(level.peak)")
}

@Test("The same 4-channel buffer WITH a discrete layout is recorded the same way (F856 control)")
func fourChannelBufferWithADiscreteLayoutIsRecorded() throws {
    // The control that makes the test above mean what it says: the fixture, the writer and the
    // read-back are sound, so a failure there is about the missing layout and nothing else. This
    // passed before the fix too — F659 already averaged a discrete layout.
    let url = try temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try FloatTrackWriter(outputURL: url, targetSampleRate: captureRate)
    _ = try #require(try writer.append(
        capturedBuffer(channels: 4, frames: 1_024, layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)
    ))
    let track = try writer.finish()
    #expect(track.frameCount == 1_024)
    let peak = try samples(of: track).reduce(0) { max($0, abs($1)) }
    let expected = toneAmplitude / 4
    #expect(abs(peak - expected) < expected * 0.01, "peak \(peak), expected \(expected)")
}

@Test("A buffer whose format cannot be read as audio throws a track-write failure, not a crash (F856)")
func unreadableBufferFormatThrowsInsteadOfCrashing() throws {
    // The branch for a description nothing can make an audio format of. A video description stands
    // in for it: `CMFormatDescription.h` says the audio getters "return NULL if used with a non-audio
    // format description", and before the fix this buffer crashed `append` with SIGSEGV at the same
    // line as the 4-channel case (measured). A throw from `append` is what the sample handler
    // already treats as one failed write: `_streamError` plus `recordWriteOutcome(succeeded: false)`
    // (F363, F386), while the other track keeps recording.
    var video: CMVideoFormatDescription?
    let made = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: 2, height: 2,
        extensions: nil, formatDescriptionOut: &video
    )
    try #require(made == noErr)
    let videoFormat: CMVideoFormatDescription = try #require(video)
    var sampleBuffer: CMSampleBuffer?
    let created = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    )
    try #require(created == noErr)
    let buffer = try #require(sampleBuffer)

    let url = try temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try FloatTrackWriter(outputURL: url, targetSampleRate: captureRate)
    #expect(throws: AudioCaptureError.self) {
        _ = try writer.append(buffer)
    }
    // Nothing was written for it, and the track still finishes as an empty, valid track.
    #expect(try writer.finish().frameCount == 0)
}

/// An audio description of the given shape, with or without a layout.
private func audioDescription(
    channels: UInt32, float: Bool, interleaved: Bool, layoutTag: AudioChannelLayoutTag?
) throws -> CMAudioFormatDescription {
    let bytes: UInt32 = float ? 4 : 2
    var flags: AudioFormatFlags = (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
    if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
    let frameBytes = interleaved ? bytes * channels : bytes
    var asbd = AudioStreamBasicDescription(
        mSampleRate: captureRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
        mChannelsPerFrame: channels, mBitsPerChannel: bytes * 8, mReserved: 0
    )
    var description: CMAudioFormatDescription?
    var layout = AudioChannelLayout(
        mChannelLayoutTag: layoutTag ?? 0, mChannelBitmap: [], mNumberChannelDescriptions: 0,
        mChannelDescriptions: AudioChannelDescription()
    )
    let status = layoutTag == nil
        ? CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                         magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                         formatDescriptionOut: &description)
        : CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                         layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                         magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                         formatDescriptionOut: &description)
    try #require(status == noErr)
    return try #require(description)
}

@Test("Where the old format initializer worked, the new one reads the same format (F856 control)")
func formatDerivationMatchesTheOldInitializerWhereItWorked() throws {
    // The shapes the capture path really sees go through the new derivation unchanged: same channel
    // count, sample format, interleaving, rate and layout tag. Compared field by field, because
    // `AVAudioFormat`'s equality reported two `Unknown | 4` formats with the same tag unequal.
    let shapes: [(String, UInt32, Bool, Bool, AudioChannelLayoutTag?)] = [
        ("mono float", 1, true, false, nil),
        ("stereo float, no layout", 2, true, false, nil),
        ("stereo float, Stereo layout", 2, true, false, kAudioChannelLayoutTag_Stereo),
        ("stereo Int16 interleaved", 2, false, true, nil),
        ("4 ch float, DiscreteInOrder", 4, true, false, kAudioChannelLayoutTag_DiscreteInOrder | 4),
        ("4 ch float, Unknown", 4, true, false, kAudioChannelLayoutTag_Unknown | 4),
    ]
    for (name, channels, float, interleaved, tag) in shapes {
        let description = try audioDescription(channels: channels, float: float, interleaved: interleaved, layoutTag: tag)
        let old = AVAudioFormat(cmAudioFormatDescription: description)
        // The old initializer's nil is an object no optional can hold; this is how to see it.
        try #require(unsafeBitCast(old, to: UnsafeRawPointer?.self) != nil, "\(name): the old initializer failed here")
        let new = try #require(FloatTrackWriter.inputFormat(of: description), "\(name): the new derivation said no")
        #expect(new.channelCount == old.channelCount, "\(name)")
        #expect(new.commonFormat == old.commonFormat, "\(name)")
        #expect(new.isInterleaved == old.isInterleaved, "\(name)")
        #expect(new.sampleRate == old.sampleRate, "\(name)")
        #expect(new.channelLayout?.layoutTag == old.channelLayout?.layoutTag, "\(name)")
    }

    // And where the old one returned its unchecked nil, the new one gives a usable discrete format.
    for channels: UInt32 in [3, 4, 6] {
        let description = try audioDescription(channels: channels, float: true, interleaved: false, layoutTag: nil)
        let format = try #require(FloatTrackWriter.inputFormat(of: description))
        #expect(format.channelCount == channels)
        #expect(format.channelLayout?.layoutTag == kAudioChannelLayoutTag_DiscreteInOrder | channels)
    }
}
