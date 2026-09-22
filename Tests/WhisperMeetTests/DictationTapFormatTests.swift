import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F356 — on 2026-09-21 the app aborted twice from `MicDictationRecorder.start`. In the pre-fix file
// (c58351a) the input format was read at `:50` and handed to `installTap` at `:66`; enabling the input
// stream reconfigured the device in between, so AVFAudio raised an NSException that Swift cannot catch.
// Those line numbers are the crashing file's, not this tree's — the fix moved them. The two crashes
// disagreed about which rate was stale (48000 then 24000, then 24000 then 48000), which is what
// proves no pinned value is correct.
//
// The abort needs a real audio device to change rate inside a 22 ms window, which this target cannot
// stage and which `swift test` must never depend on. So the regression witness is a source assertion
// — the F306/F174 precedent for a failure whose entry point the harness cannot drive — and the
// behaviour the fix introduces is covered directly, headlessly, below it.

private let recorderSource = "Sources/WhisperMeet/Dictation/MicDictationRecorder.swift"

@Test("The dictation tap never pins a client format (F356)")
func dictationTapInstallsWithoutAPinnedFormat() throws {
    let source = try SourceAssertion.uncommentedSource(recorderSource)
    #expect(source.contains("format: nil"), "a non-nil format is what AVFAudio validates and raises on")
    #expect(!source.contains("format: inputFormat"), "the read-then-install race is exactly this argument")
}

@Test("The microphone-availability guard uses the documented hardware probe (F358)")
func dictationGuardProbesTheHardwareFormat() throws {
    let source = try SourceAssertion.uncommentedSource(recorderSource)
    // AVAudioEngine.h, `inputNode`: "Check for the input node's input format (i.e. hardware format)
    // for non-zero sample rate and channel count to see if input is enabled."
    //
    // Both clauses, separately: a two-clause guard becomes a one-clause guard in a later edit, and
    // the behavioural counterpart is `eitherHalfOfTheProbeRefuses` in `DictationCaptureLossTests`,
    // which F367's probe seam made possible and which is the stronger of the two checks.
    #expect(source.contains("engine.inputNode.inputFormat(forBus: 0)"))
    #expect(source.contains("hardwareFormat.sampleRate > 0"))
    #expect(source.contains("hardwareFormat.channels > 0"))
    // The property NOT to read. F356's crash came from `outputFormat`, whose value the engine is
    // free to change when it enables input; the header's availability sentences name `inputFormat`.
    #expect(!source.contains("outputFormat(forBus:"))
}

/// `seconds` of a 440 Hz sine at `amplitude`, mono float — the shape a tap delivers.
///
/// A sine rather than a constant, because a resampler is exactly the thing a DC signal cannot probe;
/// and 0.1 amplitude rather than full scale, because the meter is `min(1, rms * 8)` and any amplitude
/// above ~0.177 saturates it, which would make every level assertion below pass by construction.
private func toneBuffer(
    sampleRate: Double,
    seconds: Double = 0.1,
    amplitude: Float = 0.1
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    ))
    let frames = AVAudioFrameCount(saturating: sampleRate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        channel[index] = amplitude * Float(sin(2 * .pi * 440 * Double(index) / sampleRate))
    }
    return buffer
}
@Test("A mid-stream input format change still converts to the dictation sample rate (F356)")
func converterRebuildsWhenTheInputFormatChanges() throws {
    let converter = try #require(DictationTapConverter(targetSampleRate: 16_000))

    // Half a second at 48 kHz, then half a second at 24 kHz: the exact transition the two crashes
    // rode in on, except arriving mid-capture instead of at the tap install.
    var total = 0
    var afterTheChange = 0
    for _ in 0..<5 {
        total += try #require(converter.convert(try toneBuffer(sampleRate: 48_000))).samples.count
    }
    for _ in 0..<5 {
        let chunk = try #require(converter.convert(try toneBuffer(sampleRate: 24_000)))
        #expect(chunk.samples.count > 0, "conversion stopped producing audio after the format change")
        // A real value, not `0...1`: the meter is `min(1, rms * 8)`, so a `0...1` bound is satisfied by
        // construction for any non-silent buffer — and by a NaN, since `min(1, .nan)` is 1. A 0.1
        // amplitude sine has rms 0.0707, so the meter must read 0.566; measured 0.5652–0.5662 across
        // both rates, and resampling is what makes it a band rather than a point.
        #expect(abs(chunk.level - 0.566) < 0.02, "meter read \(chunk.level), expected ~0.566")
        total += chunk.samples.count
        afterTheChange += chunk.samples.count
    }

    // One second of input must still be one second of 16 kHz output. It is a little short, not
    // exact, because a sample-rate converter primes its filter on the first buffer after each
    // build — measured at 240 samples for 48 kHz and 11 for 24 kHz, 0.77% of the clip in total.
    // Asserting the accumulated duration rather than a per-buffer count on purpose: the per-buffer
    // figure also depends on the output buffer's headroom draining the priming backlog, which is an
    // artefact of the capacity we ask for and not a property worth pinning.
    #expect(total >= 15_800 && total <= 16_000, "1.0 s of input produced \(total) samples at 16 kHz")
    #expect(afterTheChange >= 7_900, "0.5 s after the change produced \(afterTheChange) samples")
}

@Test("Converting the same format twice reuses one converter, and a change rebuilds it (F356)")
func converterIsRebuiltOnlyWhenTheFormatChanges() throws {
    let converter = try #require(DictationTapConverter(targetSampleRate: 16_000))

    _ = converter.convert(try toneBuffer(sampleRate: 48_000))
    #expect(converter.rebuildCountForTesting == 1)
    _ = converter.convert(try toneBuffer(sampleRate: 48_000))
    #expect(converter.rebuildCountForTesting == 1, "an unchanged format must not rebuild per buffer")
    _ = converter.convert(try toneBuffer(sampleRate: 24_000))
    #expect(converter.rebuildCountForTesting == 2)
}

@Test("The tap asks for a buffer size inside AVFAudio's documented range (F359)")
func theTapBufferSizeIsInTheDocumentedRange() throws {
    // `AVAudioNode.h`: "the requested size of the incoming buffers in sample frames. Supported
    // range is [100, 400] ms." The old value, 1,024 frames, is 21.3 ms at 48 kHz — a twentieth of
    // the minimum — and AVFAudio silently delivered 4,800 instead. Measured on real hardware,
    // which is the only way that could be known:
    //
    //     requested 1,024 -> delivered 4,800    requested 8,192  -> delivered 8,192
    //     requested 4,800 -> delivered 4,800    requested 19,200 -> delivered 19,200
    //
    // A source assertion because a test process cannot install a tap without a microphone, and
    // `swift test` must never need one.
    let source = try SourceAssertion.uncommentedSource(recorderSource)
    let call = try #require(source.range(of: "installTap(onBus: 0, bufferSize: "))
    let tail = source[call.upperBound...]
    let digits = String(tail.prefix(while: { $0.isNumber || $0 == "_" })).replacingOccurrences(of: "_", with: "")
    let frames = try #require(Double(digits))
    // At the 48 kHz this Mac's input runs at. Stated as the rate rather than left implicit,
    // because a frame count is only in range relative to one.
    let milliseconds = frames / 48_000 * 1_000
    #expect(milliseconds >= 100 && milliseconds <= 400,
            "\(frames) frames is \(milliseconds) ms at 48 kHz, outside the documented [100, 400]")
}
