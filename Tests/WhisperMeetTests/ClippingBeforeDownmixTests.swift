import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F419 — clipping is counted per input channel, BEFORE the downmix.
//
// F398 made the capture path mix its two channels rather than keep the left one, and F346's
// full-scale count ran over that mono mix. A source clipped on the right channel alone averages to
// 0.5 in the mix, so it did not count: clipping is distortion that already happened at the source,
// and averaging scales the flattened waveform down without unflattening it. The user decided
// (NEEDS_HUMAN, 2026-09-24) that the count belongs before the downmix.
//
// These drive `CaptureLevelMeter.measure` — the function `FloatTrackWriter.append` returns — with
// buffers converted by the production `MonoDownmixConverter.make`, the same shape as
// `StereoDownmixTests`. The dual-mono controls are the ticket's "the common case did not move".

private let meterRate: Double = 48_000

private func stereoBuffer(
    frames: AVAudioFrameCount = 2_400,
    sampleRate: Double = meterRate,
    interleaved: Bool = false,
    sample: (_ frame: Int, _ channel: Int) -> Float
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: interleaved
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<Int(frames) {
        if interleaved {
            channels[0][frame * 2] = sample(frame, 0)
            channels[0][frame * 2 + 1] = sample(frame, 1)
        } else {
            channels[0][frame] = sample(frame, 0)
            channels[1][frame] = sample(frame, 1)
        }
    }
    return buffer
}

/// The input and its mono conversion, through the production converter, measured by production code.
private func measure(_ input: AVAudioPCMBuffer) throws -> (level: RecordingAudioLevel, outputFrames: Int) {
    let target = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: meterRate, channels: 1, interleaved: false
    ))
    let converter = try #require(MonoDownmixConverter.make(from: input.format, to: target))
    let ratio = meterRate / input.format.sampleRate
    let output = try #require(AVAudioPCMBuffer(
        pcmFormat: target,
        frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
    ))
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return input
    }
    #expect(error == nil, "conversion failed: \(String(describing: error))")
    return (CaptureLevelMeter.measure(input: input, output: output), Int(output.frameLength))
}

@Test("A full-scale right channel with a silent left counts as clipped (F419)")
func rightOnlyFullScaleCountsBeforeTheDownmix() throws {
    let (level, outputFrames) = try measure(stereoBuffer { _, channel in channel == 1 ? 1.0 : 0 })
    try #require(outputFrames == 2_400)
    // The ticket's own case. After the downmix every sample is 0.5, nowhere near the rail, and the
    // old count said 0 — while the source was flat-topped for every frame.
    #expect(level.framesAtFullScale == 2_400)
    // Still frames, not frames × channels: I chose that so the persisted unit, `ClippedSecond`'s
    // "count is duration", and `atFullScale <= measured` all survive unchanged.
    #expect(level.framesMeasured == 2_400)
    // The meter still describes the file: peak and rms stay post-downmix.
    #expect(abs(level.peak - 0.5) < 0.01)
}

@Test("A frame counts once when either channel is at the rail, not once per channel (F419)")
func aFrameCountsOnceWhicheverChannelClipped() throws {
    // Left clips on the first 100 frames, right on frames 50..<250: 250 distinct frames clipped,
    // 300 channel-samples. Frames is the unit.
    let (level, _) = try measure(stereoBuffer { frame, channel in
        channel == 0 ? (frame < 100 ? -1.0 : 0) : (frame >= 50 && frame < 250 ? 1.0 : 0)
    })
    #expect(level.framesAtFullScale == 250)
    #expect(level.framesMeasured == 2_400)
}

@Test("An interleaved capture is read with its stride, not as one long channel (F419)")
func interleavedInputIsReadWithItsStride() throws {
    // The right channel clips on its first 100 frames only, at the odd samples 1, 3, …, 199 of
    // the one interleaved chunk. Read with the stride, frame f looks at samples 2f and 2f+1 and
    // finds 100 clipped frames. Read without it, frame f looks at f and f+1, and frames 0 through
    // 199 each touch one of those odd samples: 200. A fixture that clipped EVERY right-channel
    // frame could not tell the two apart, because every frame then touches an odd sample either way.
    let (level, outputFrames) = try measure(
        stereoBuffer(interleaved: true) { frame, channel in channel == 1 && frame < 100 ? 1.0 : 0 }
    )
    try #require(outputFrames == 2_400)
    #expect(level.framesAtFullScale == 100)
    #expect(level.framesMeasured == 2_400)
}

@Test("Dual-mono audio is counted exactly as before the change (F419 control)")
func dualMonoClippingIsUnchanged() throws {
    let clipped = try measure(stereoBuffer { _, _ in 1.0 }).level
    #expect(clipped.framesAtFullScale == 2_400)
    #expect(clipped.framesMeasured == 2_400)

    let loudButClean = try measure(stereoBuffer { _, _ in 0.5 }).level
    #expect(loudButClean.framesAtFullScale == 0)
    #expect(loudButClean.framesMeasured == 2_400)
}

@Test("A mono input is counted exactly as before the change (F419 control)")
func monoInputClippingIsUnchanged() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: meterRate, channels: 1, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    let channel = try #require(buffer.floatChannelData)[0]
    for frame in 0..<2_400 { channel[frame] = frame < 600 ? 1.0 : 0.25 }
    let level = try measure(buffer).level
    #expect(level.framesAtFullScale == 600)
    #expect(level.framesMeasured == 2_400)
}

@Test("A resampled capture's count stays in output frames and never exceeds them (F419)")
func resampledInputKeepsTheCountInOutputFrames() throws {
    // 44.1 kHz in, 48 kHz out. The count is taken over input frames and mapped to the output rate,
    // because `framesMeasured` is output frames and the ratio feeds the advisory's bands.
    let (level, outputFrames) = try measure(
        stereoBuffer(frames: 4_410, sampleRate: 44_100) { _, channel in channel == 1 ? 1.0 : 0 }
    )
    try #require(outputFrames > 0)
    let atFullScale = try #require(level.framesAtFullScale)
    #expect(level.framesMeasured == outputFrames)
    #expect(atFullScale > 0, "every input frame clipped on the right, so the count must see it")
    #expect(atFullScale <= outputFrames, "a count past framesMeasured is the incoherence F400 guards")
}

@Test("The capture writer hands the meter the buffer as captured, not only the mix (F419)")
func theWriterMeasuresTheCapturedBuffer() throws {
    // No test builds a `CMSampleBuffer` to drive `FloatTrackWriter.append` itself, so the wiring
    // from the writer to the per-channel count is pinned as source, comments stripped.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    #expect(source.contains("CaptureLevelMeter.measure(input: inputBuffer, output: outputBuffer)"))
}
