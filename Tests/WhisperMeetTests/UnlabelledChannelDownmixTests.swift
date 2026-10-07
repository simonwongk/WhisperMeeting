import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F659 — an input whose channels carry no speaker labels was converted to silence.
//
// `AVAudioConverter` decides how to fold channels by reading the channel layout. With `downmix` on
// (F398) it mixes stereo and speaker-labelled layouts, but a layout that names no speakers — a
// `DiscreteInOrder` or `Unknown` tag, which a multi-input audio interface can report — has nothing
// for it to mix by, and the mono output is all zeros. Not the first channel kept and the
// rest dropped: every channel, the first one included. Measured on this Mac before the fix, through
// the production `MonoDownmixConverter.make` with `downmix` on, 48 kHz in:
//
//     2ch DiscreteInOrder|2 -> peak 0.0      4ch Unknown|4         -> peak 0.0
//     3ch DiscreteInOrder|3 -> peak 0.0      6ch DiscreteInOrder|6 -> peak 0.0
//     4ch DiscreteInOrder|4 -> peak 0.0      (a tone in channel 0 only: also 0.0)
//     2ch, no layout        -> peak 0.25     4ch Quadraphonic -> 0.1036   6ch MPEG 5.1 A -> 0.0732
//
// F581 found it in the segment decoder and averaged by hand there. Meeting capture's microphone
// track arrives in "the selected microphone capture device's native format" (`SCStream.h`, on
// `SCStreamOutputTypeMicrophone`), and the dictation tap in the input node's, so both paths met the
// same converter with whatever layout the hardware reports.
//
// Every fixture carries its tone in ONE channel and silence in the rest, so a converter that drops
// the layout reads 0, a remap to channel 0 reads 0 when the tone is elsewhere, and only an average of
// every channel reads amplitude / channels.

private let toneAmplitude: Float = 0.5
private let captureRate: Double = 48_000

/// A 440 Hz tone in `toneChannel`, silence in every other channel, with the given layout.
private func unlabelledBuffer(
    layoutTag: AudioChannelLayoutTag,
    toneChannel: Int? = nil,
    commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
    interleaved: Bool = false,
    frames: AVAudioFrameCount = 4_800
) throws -> AVAudioPCMBuffer {
    let layout = try #require(AVAudioChannelLayout(layoutTag: layoutTag))
    let format = AVAudioFormat(
        commonFormat: commonFormat, sampleRate: captureRate, interleaved: interleaved, channelLayout: layout
    )
    let channels = Int(format.channelCount)
    let tone = toneChannel ?? channels - 1
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    // Written through the raw buffer list, so one writer covers every sample format and both
    // interleavings: a deinterleaved buffer has one `AudioBuffer` per channel, an interleaved one a
    // single buffer whose frames are `channels` samples wide.
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for audioBuffer in list { memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize)) }
    for frame in 0..<Int(frames) {
        let value = Double(toneAmplitude) * sin(2 * Double.pi * 440 * Double(frame) / captureRate)
        let (bufferIndex, offset) = interleaved ? (0, frame * channels + tone) : (tone, frame)
        let data = try #require(list[bufferIndex].mData)
        switch commonFormat {
        case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[offset] = Int16(value * 32_767)
        case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[offset] = Int32(value * 2_147_483_647)
        case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[offset] = value
        default: data.assumingMemoryBound(to: Float.self)[offset] = Float(value)
        }
    }
    return buffer
}

private func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

/// The capture path's conversion, through the production pieces in the order
/// `FloatTrackWriter.append` uses them: `averagedToMono`, then a converter from `make`, fed the mixed
/// buffer once. `append` itself takes a `CMSampleBuffer` on the capture queue, which no test here can
/// drive (F402, F419); `theCapturePathMixesBeforeItConverts` pins that `append` makes these calls.
private func captureConvert(_ input: AVAudioPCMBuffer) throws -> [Float] {
    let target = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: captureRate, channels: 1, interleaved: false
    ))
    let mono = try #require(MonoDownmixConverter.averagedToMono(input))
    let converter = try #require(MonoDownmixConverter.make(from: mono.format, to: target))
    let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: mono.frameLength + 32))
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if supplied { inputStatus.pointee = .noDataNow; return nil }
        supplied = true
        inputStatus.pointee = .haveData
        return mono
    }
    #expect(status != .error && error == nil, "conversion failed: \(String(describing: error))")
    let channel = try #require(output.floatChannelData)[0]
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

/// One fixture: the layout, which channel carries the tone, and how the samples are stored.
struct UnlabelledLayoutCase: CustomTestStringConvertible, Sendable {
    let name: String
    let layoutTag: AudioChannelLayoutTag
    let channels: Int
    var toneChannel: Int? = nil
    var commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    var interleaved = false

    var testDescription: String { name }
    /// The average of one toned channel and `channels - 1` silent ones.
    var expectedPeak: Float { toneAmplitude / Float(channels) }
}

private let unlabelledCases: [UnlabelledLayoutCase] = [
    UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, tone in the last", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4),
    UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, tone in the first", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4, toneChannel: 0),
    UnlabelledLayoutCase(name: "4 ch Unknown, tone in the last", layoutTag: kAudioChannelLayoutTag_Unknown | 4, channels: 4),
    UnlabelledLayoutCase(name: "3 ch DiscreteInOrder, tone in the last", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3, channels: 3),
    UnlabelledLayoutCase(name: "6 ch DiscreteInOrder, tone in the last", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6, channels: 6),
    UnlabelledLayoutCase(name: "2 ch DiscreteInOrder, tone in the last", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 2, channels: 2),
    UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, interleaved float", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4, interleaved: true),
]

// MARK: - The dictation path, end to end through its real converter

@Test("Dictation keeps a tone carried by any channel of an unlabelled layout (F659)", arguments: unlabelledCases)
func dictationAveragesAnUnlabelledLayout(_ fixture: UnlabelledLayoutCase) throws {
    let converter = try #require(DictationTapConverter(targetSampleRate: 16_000))
    let buffer = try unlabelledBuffer(
        layoutTag: fixture.layoutTag, toneChannel: fixture.toneChannel,
        commonFormat: fixture.commonFormat, interleaved: fixture.interleaved
    )
    let chunk = try #require(converter.convert(buffer), "the converter yielded no chunk at all")
    // 48 kHz to 16 kHz, so the 440 Hz peak is read off a resampled sine: within 5%, measured well
    // inside that. A silent conversion reads 0 and a remap to channel 0 reads 0 for every tone not in
    // channel 0.
    let measured = peak(chunk.samples)
    #expect(abs(measured - fixture.expectedPeak) < fixture.expectedPeak * 0.05,
            "\(fixture.name): peak \(measured), expected \(fixture.expectedPeak), the average of every channel")

    // The averaged buffer is a fresh object each time, so the converter is matched on its format's
    // equality, not its identity. A rebuild per buffer would pass the peak above and still cut a gap
    // into every buffer: a rebuild discards the resampler's priming (240 samples at 48 kHz to 16 kHz,
    // DictationTapFormatTests).
    _ = try #require(converter.convert(unlabelledBuffer(
        layoutTag: fixture.layoutTag, toneChannel: fixture.toneChannel,
        commonFormat: fixture.commonFormat, interleaved: fixture.interleaved
    )))
    #expect(converter.rebuildCountForTesting == 1, "\(fixture.name): the same format rebuilt the converter")
}

// MARK: - The capture path, through the production pieces it calls

@Test(
    "Meeting capture keeps a tone carried by any channel of an unlabelled layout, in any sample format (F659)",
    arguments: unlabelledCases + [
        UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, interleaved Int16", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4, commonFormat: .pcmFormatInt16, interleaved: true),
        UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, Int32", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4, commonFormat: .pcmFormatInt32),
        UnlabelledLayoutCase(name: "4 ch DiscreteInOrder, Float64", layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4, channels: 4, commonFormat: .pcmFormatFloat64),
    ]
)
func captureAveragesAnUnlabelledLayout(_ fixture: UnlabelledLayoutCase) throws {
    let samples = try captureConvert(unlabelledBuffer(
        layoutTag: fixture.layoutTag, toneChannel: fixture.toneChannel,
        commonFormat: fixture.commonFormat, interleaved: fixture.interleaved
    ))
    try #require(!samples.isEmpty, "\(fixture.name): the conversion produced no frames")
    // 48 kHz in and out, as `AudioCaptureEngine` asks for, so the sine is sampled at the same points
    // and the peak is exact up to the 16-bit fixture's quantisation.
    let measured = peak(samples)
    #expect(abs(measured - fixture.expectedPeak) < fixture.expectedPeak * 0.01,
            "\(fixture.name): peak \(measured), expected \(fixture.expectedPeak), the average of every channel")
}

// MARK: - The wiring, which no headless test can drive for capture

@Test("Both capture paths average their channels before the converter sees them (F659)")
func theCapturePathMixesBeforeItConverts() throws {
    // A source assertion for the meeting path, whose entry point is a `CMSampleBuffer` handler on a
    // private queue (F402's reachability note): `captureAveragesAnUnlabelledLayout` drives the
    // production pieces, and this pins that `FloatTrackWriter.append` is what calls them, on the
    // mixed buffer. The dictation path is driven end to end above; it is listed too, so the two
    // copies of this conversion cannot drift apart again (F376's shape).
    for path in [
        "Sources/WhisperMeet/AudioCaptureEngine.swift",
        "Sources/WhisperMeet/Dictation/DictationTapConverter.swift",
    ] {
        let source = try SourceAssertion.uncommentedSource(path)
        // Bound to names first, so a failure prints the sentence and not the whole file.
        let averages = source.contains("MonoDownmixConverter.averagedToMono(")
        let buildsFromTheAverage = source.contains("MonoDownmixConverter.make(from: mono.format")
        #expect(averages, "\(path) must average its channels by hand before converting")
        #expect(buildsFromTheAverage,
                "\(path) must build its converter from the averaged buffer's format, not the device's")
    }
}
