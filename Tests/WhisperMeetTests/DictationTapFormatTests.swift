import AVFoundation
import Foundation
import Testing
@testable import WhisperMeet

// F356 — on 2026-09-21 the app aborted twice from `MicDictationRecorder.start`. The input format was
// read at `:50` and handed to `installTap` at `:66`, and enabling the input stream reconfigured the
// device in between, so AVFAudio raised an NSException that Swift cannot catch. The two crashes
// disagreed about which rate was stale (48000 then 24000, then 24000 then 48000), which is what
// proves no pinned value is correct.
//
// The abort needs a real audio device to change rate inside a 22 ms window, which this target cannot
// stage and which `swift test` must never depend on. So the regression witness is a source assertion
// — the F306/F174 precedent for a failure whose entry point the harness cannot drive — and the
// behaviour the fix introduces is covered directly, headlessly, below it.

private func uncommentedSource(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent(path)
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")
}

private let recorderSource = "Sources/WhisperMeet/Dictation/MicDictationRecorder.swift"

@Test("The dictation tap never pins a client format (F356)")
func dictationTapInstallsWithoutAPinnedFormat() throws {
    let source = try uncommentedSource(recorderSource)
    #expect(source.contains("format: nil"), "a non-nil format is what AVFAudio validates and raises on")
    #expect(!source.contains("format: inputFormat"), "the read-then-install race is exactly this argument")
}

@Test("The microphone-availability guard uses the documented hardware probe (F358)")
func dictationGuardProbesTheHardwareFormat() throws {
    let source = try uncommentedSource(recorderSource)
    // AVAudioEngine.h, `inputNode`: "Check for the input node's input format (i.e. hardware format)
    // for non-zero sample rate and channel count to see if input is enabled."
    #expect(source.contains("input.inputFormat(forBus: 0)"))
    #expect(source.contains("hardwareFormat.sampleRate > 0"))
    #expect(source.contains("hardwareFormat.channelCount > 0"))
}
/// 0.1 s of full-scale tone at `sampleRate`, mono float — the shape a tap delivers.
private func toneBuffer(sampleRate: Double, seconds: Double = 0.1) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    ))
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        channel[index] = sin(2 * .pi * 440 * Double(index) / sampleRate).magnitude > 0 ? 1 : -1
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
        #expect(chunk.level.isFinite && chunk.level >= 0 && chunk.level <= 1, "level \(chunk.level)")
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
