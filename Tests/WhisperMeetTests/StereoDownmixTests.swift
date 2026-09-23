import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F398 — multi-channel input reaching a mono track must be MIXED, not remapped.
//
// `AVAudioConverter` defaults `downmix` to NO, and `AVAudioConverter.h:211-216` says so in as many
// words: "If YES and channel remapping is necessary, then channels will be mixed as appropriate
// instead of remapped. Default value is NO." Remapping a stereo source to one channel keeps
// channel 0 and discards the rest, so anything present only in the right channel never reached
// `system-audio.f32`, `meeting.wav`, or the transcript — and because the recording is the source
// of truth and is already mono on disk, re-transcribing could not recover it.
//
// `AudioCaptureEngine` asks ScreenCaptureKit for two channels outright
// (`configuration.channelCount = 2`), so the capture path is always in the remapping case. The
// dictation path depends on the hardware and may or may not be.
//
// The assertions below are on amplitude, because that is what the defect changes: a hard-panned
// source is silent before the fix and half-amplitude (−6 dB) after it, while dual-mono — which is
// what ordinary call audio is — is unchanged either way. The dual-mono control is the important
// half: a "fix" that halved every existing recording's level would also turn 0.0 into 0.25 here.

private let downmixRate: Double = 48_000

/// A constant-valued stereo buffer, the shape a tap or a converted `CMSampleBuffer` delivers.
private func stereoBuffer(
    left: Float,
    right: Float,
    frames: AVAudioFrameCount = 2_400,
    sampleRate: Double = downmixRate
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<Int(frames) {
        channels[0][frame] = left
        channels[1][frame] = right
    }
    return buffer
}

/// The largest absolute sample, which is what "did the right channel survive" reduces to here.
private func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

/// Runs one buffer through a converter built by the **production** helper.
///
/// The driver lives here rather than in `Sources/` on purpose. What the capture path and the
/// dictation path genuinely share is the converter's *construction* — the surrounding plumbing
/// differs (a `CMSampleBuffer` on one side, an `AVAudioPCMBuffer` on the other) — so the shared
/// production code is `MonoDownmixConverter.make`, and that is what these tests exercise. A
/// convert-for-testing entry point in the app target would be a second conversion path that
/// production never takes, which is the seam F262 spent four attempts learning not to build.
private func convertToMono(
    _ input: AVAudioPCMBuffer,
    sampleRate: Double = downmixRate
) throws -> [Float] {
    let target = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    ))
    let converter = try #require(MonoDownmixConverter.make(from: input.format, to: target))
    let output = try #require(AVAudioPCMBuffer(
        pcmFormat: target, frameCapacity: input.frameLength + 32
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
    let channels = try #require(output.floatChannelData)
    return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
}

// MARK: - The dictation path

@Test("Dictation mixes a hard-panned right channel instead of dropping it (F398)")
func dictationDownmixesTheRightChannel() throws {
    let converter = try #require(DictationTapConverter(targetSampleRate: downmixRate))
    let chunk = try #require(converter.convert(stereoBuffer(left: 0, right: 0.5)))
    // Averaged, so a source present only on the right arrives at half amplitude rather than zero.
    #expect(abs(peak(chunk.samples) - 0.25) < 0.01,
            "a right-only source must survive the mono conversion, at -6 dB")
}

@Test("Dictation leaves ordinary dual-mono audio at its own level (F398)")
func dictationDualMonoKeepsItsLevel() throws {
    let converter = try #require(DictationTapConverter(targetSampleRate: downmixRate))
    let chunk = try #require(converter.convert(stereoBuffer(left: 0.5, right: 0.5)))
    // The control that makes the test above mean what it says. Mixing L and R must average them,
    // not sum them and not halve a signal that is already centred — this is every real call.
    #expect(abs(peak(chunk.samples) - 0.5) < 0.01,
            "dual-mono is what ordinary call audio is; its level must not move")
}

// MARK: - The capture path

@Test("Meeting capture mixes a hard-panned right channel instead of dropping it (F398)")
func captureDownmixesTheRightChannel() throws {
    let buffer = try stereoBuffer(left: 0, right: 0.5)
    let samples = try convertToMono(buffer)
    #expect(abs(peak(samples) - 0.25) < 0.01,
            "ScreenCaptureKit is asked for two channels, so this is the path that always remaps")
}

@Test("Meeting capture leaves ordinary dual-mono audio at its own level (F398)")
func captureDualMonoKeepsItsLevel() throws {
    let buffer = try stereoBuffer(left: 0.5, right: 0.5)
    let samples = try convertToMono(buffer)
    #expect(abs(peak(samples) - 0.5) < 0.01)
}

@Test("A mono source is untouched, so the fix costs the common case nothing (F398)")
func monoInputIsNotDownmixed() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: downmixRate, channels: 1, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<2_400 { channels[0][frame] = 0.5 }

    let samples = try convertToMono(buffer)
    // `downmix` is only set when the input has more channels than the target, so a single-channel
    // input takes the same path it always did. Asserted rather than assumed, because "mixing" one
    // channel is exactly the kind of no-op that turns out not to be one.
    #expect(abs(peak(samples) - 0.5) < 0.01)
}

// MARK: - The rule, derived rather than restated

@Test("Every converter that targets mono asks for a mix, not a remap (F398)")
func noConverterIsBuiltWithoutTheDownmixDecision() throws {
    // A source assertion, because the defect is an *absence*: `AVAudioConverter(from:to:)` with no
    // `downmix` set is silently a remap, and nothing about the call site looks wrong. Two sites had
    // it, and a third written next month would too. This fails if anyone builds one outside the
    // shared helper, which is the only place the decision is made.
    for path in [
        "Sources/WhisperMeet/AudioCaptureEngine.swift",
        "Sources/WhisperMeet/Dictation/DictationTapConverter.swift",
    ] {
        let source = try SourceAssertion.uncommentedSource(path)
        #expect(!source.contains("AVAudioConverter(from:"),
                "\(path) should build its converter through MonoDownmixConverter, which sets downmix")
        #expect(source.contains("MonoDownmixConverter.make("),
                "\(path) should use the shared helper")
    }
    let helper = try SourceAssertion.uncommentedSource(
        "Sources/WhisperMeet/MonoDownmixConverter.swift"
    )
    #expect(helper.contains("downmix = true"), "the helper is where the decision lives")
}
