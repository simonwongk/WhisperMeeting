import Foundation
import Testing
@testable import WhisperCore

// F278 — `FloatTrackMixer` produces `meeting.wav` for every recording and had no test at all, being
// `private` inside `AudioCaptureEngine.swift`. F259 covered the *recovery* mixer (ragged tracks,
// zero-padding) only because that copy is already public; the capture copy — the one that runs on
// every successful meeting — was dark.
//
// Three behaviours here are load-bearing and were resting entirely on reading the code:
//
//  1. The **gain rule**: two active tracks are summed at 0.5, a lone track at 0.95. Get this wrong
//     and every recording is either clipped or quiet, which is not the kind of bug a reader spots.
//  2. **The header is written last.** The mixer reserves 44 zero bytes, streams the PCM, then seeks
//     back. That ordering is what makes a truncated `meeting.wav` *detectable* — a zero header fails
//     `wavDuration`, so recovery falls back to the `.f32` tracks instead of trusting a short file.
//  3. **Front padding** from presentation timestamps, so a track that started late stays aligned
//     with the one that started first rather than sliding earlier in the mix.

private struct MixFixture {
    let directory: URL
    let system: URL
    let microphone: URL
    let output: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F278-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        system = directory.appendingPathComponent("system-audio.f32")
        microphone = directory.appendingPathComponent("microphone-audio.f32")
        output = directory.appendingPathComponent("meeting.wav")
    }

    func write(_ samples: [Float], to url: URL) throws {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// The Int16 samples in a mixed WAV, skipping the 44-byte header.
private func pcmSamples(of url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { return [] }
    let payload = data.dropFirst(44)
    return payload.withUnsafeBytes { raw in
        (0..<(payload.count / 2)).map {
            Int16(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self).littleEndian)
        }
    }
}

private func expectedPCM(_ value: Float) -> Int16 {
    Int16(max(-1, min(1, value)) * Float(Int16.max))
}

@Test("Loud overlap is limited rather than halved, and still cannot clip (F278, F345)")
func loudOverlapIsLimitedRatherThanHalved() throws {
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.8, count: 16), to: fixture.system)
    try fixture.write([Float](repeating: 0.6, count: 16), to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 16),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: 0, frameCount: 16),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    // 0.8 + 0.6 = 1.4 summed straight would clip hard. It used to be halved to 0.7; F345 replaced
    // that with a soft knee, so it now lands at 0.994186 — louder, and still short of full scale.
    // The old rule bought this headroom by switching gain per sample, which is what made the buzz.
    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.count == 16)
    #expect(samples.allSatisfy { $0 == 32_576 })
    #expect(samples.allSatisfy { $0 != Int16.max }, "the whole point of the knee")
}

@Test("A lone active track keeps almost all of its level (F278)")
func oneActiveTrackMixesAtNearUnityGain() throws {
    // 0.95, not 0.5: when only one side has audio — the common case, since meeting participants
    // mostly do not talk over each other — halving it would make every recording quiet.
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.5, count: 16), to: fixture.system)
    try fixture.write([Float](repeating: 0, count: 16), to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 16),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: 0, frameCount: 16),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.allSatisfy { $0 == expectedPCM(0.5 * 0.95) })
}

@Test("A track carrying only room noise does not duck the other one (F278, F345)")
func lowLevelNoiseDoesNotDuckTheOtherTrack() throws {
    // There is no activity floor any more. It was `abs(sample) > 0.01` on both sides, and F345
    // removed it because deciding a gain from an instantaneous sample modulates the audio. The
    // property it was protecting survives and is what is asserted here: a track carrying only room
    // hiss adds its own small level and nothing else — it cannot halve the other participant.
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.5, count: 16), to: fixture.system)
    try fixture.write([Float](repeating: 0.005, count: 16), to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 16),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: 0, frameCount: 16),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.allSatisfy { $0 == expectedPCM((0.5 + 0.005) * 0.95) })
}

@Test("A track that started late is padded at the front, not slid earlier (F278)")
func laterTrackIsFrontPadded() throws {
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.5, count: 8), to: fixture.system)
    try fixture.write([Float](repeating: 0.5, count: 8), to: fixture.microphone)

    // The microphone's first buffer arrived 4 frames later at 48 kHz.
    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 100.0, frameCount: 8),
        microphone: FloatTrack(
            url: fixture.microphone,
            firstPresentationTime: 100.0 + 4.0 / 48_000.0,
            frameCount: 8
        ),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.count == 12, "the mix should span the padded microphone track")
    // Frames 0-3: system alone. 4-7: both. 8-11: microphone alone, after the system track ran out.
    #expect(Array(samples[0..<4]).allSatisfy { $0 == expectedPCM(0.5 * 0.95) })
    // 0.5 + 0.5 = 1.0, exactly at the knee, so this is still the linear part of the curve.
    #expect(Array(samples[4..<8]).allSatisfy { $0 == expectedPCM(1.0 * FloatTrackMixer.soloGain) })
    #expect(Array(samples[8..<12]).allSatisfy { $0 == expectedPCM(0.5 * 0.95) })
}

@Test("The mixed file carries the canonical header and the real data size (F278)")
func mixWritesTheCanonicalHeaderLast() throws {
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.25, count: 100), to: fixture.system)
    try fixture.write([], to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 100),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: nil, frameCount: 0),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    let data = try Data(contentsOf: fixture.output)
    #expect(data.count == 44 + 200)
    // Byte-identical to the one source of truth (the other half of F278), not merely "a valid header".
    #expect(data.prefix(44) == WAVWriter.header(sampleRate: 48_000, dataByteCount: 200))
}

@Test("The reported duration is the frames actually written (F278)")
func durationReflectsWrittenFrames() throws {
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.25, count: 24_000), to: fixture.system)
    try fixture.write([], to: fixture.microphone)

    let duration = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 24_000),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: nil, frameCount: 0),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    #expect(abs(duration - 0.5) < 0.000_1)
}

@Test("Two tracks that never received a buffer are an error, not a zero-length WAV (F278)")
func noPresentationTimeAtAllThrows() throws {
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([], to: fixture.system)
    try fixture.write([], to: fixture.microphone)

    #expect(throws: FloatTrackMixError.noAudioCaptured) {
        _ = try FloatTrackMixer.mix(
            system: FloatTrack(url: fixture.system, firstPresentationTime: nil, frameCount: 0),
            microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: nil, frameCount: 0),
            sampleRate: 48_000,
            outputURL: fixture.output
        )
    }
}

@Test("A mix longer than one chunk is continuous across the chunk boundary (F278)")
func mixSpansChunkBoundaries() throws {
    // The loop reads 8,192 frames at a time. An off-by-one there would leave a click or a gap
    // every 170 ms of a real recording — audible, and invisible in any test that stays under one
    // chunk, which is every test written above.
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    let frames = 8_192 * 2 + 33
    try fixture.write([Float](repeating: 0.4, count: frames), to: fixture.system)
    try fixture.write([Float](repeating: 0.4, count: frames), to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: Int64(frames)),
        microphone: FloatTrack(
            url: fixture.microphone,
            firstPresentationTime: 0,
            frameCount: Int64(frames)
        ),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.count == frames)
    #expect(samples.allSatisfy { $0 == expectedPCM(0.8 * FloatTrackMixer.soloGain) },
            "a chunk boundary changed the mix")
}

// MARK: - The gain rule, which existed in three copies (F278)

// A correction to F278's own text, and to the review it came from: the claim was "three copies of
// the WAV header builder". That was wrong — there were two, because `FloatTrackMixer` already called
// `WAVWriter.header`. But there really are three copies of the *mixing* arithmetic, and one of them
// hid behind the miscount: the capture mixer, the recovery rebuild
// (`InterruptedRecordingRecovery.swift:146-153`), and — before F278 — the engine's private copy.
//
// The numbers are a judgement about how two microphones sum. Two independent copies of a judgement
// drift, and the divergence would be audible in exactly one of the two paths: the one that runs
// after a recording was interrupted, where nobody has the original to compare to.
//
// F345 changed what the judgement IS — 0.01 / 0.5 / 0.95 became a single curve — without changing
// where it lives. `mixedSample` is still one pure function of one frame, which is why the recovery
// rebuild needed no edit at all, and why mixing at chunk sizes 1, 100 and 8,192 is byte-identical.
// A stateful fix would have had to reproduce its state across both paths and every chunk size,
// including the 100 that `RecoveryTruncationTests` uses.

@Test("The gain rule is one function, and it is the rule the mixer applies (F278)")
func gainRuleIsSharedAndCorrect() {
    // Past the knee: 0.994186, not 1.4 * 0.5. See `loudOverlapIsLimitedRatherThanHalved`.
    #expect(FloatTrackMixer.mixedSample(system: 0.8, microphone: 0.6) == 32_576)
    #expect(FloatTrackMixer.mixedSample(system: 0.5, microphone: 0) == expectedPCM(0.5 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: 0.5) == expectedPCM(0.5 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0.005, microphone: 0.5)
        == expectedPCM(0.505 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: 0) == 0)

    // Two full-scale tracks sum to 2.0 and come back at 32,685 — under full scale, because the
    // curve's ceiling is below 1.0 and is reached only in the limit. The `min`/`max` clamp behind it
    // is now unreachable for finite input and is kept for NaN, which `min(1, nan)` resolves to 1.0
    // rather than trapping.
    #expect(FloatTrackMixer.mixedSample(system: 1, microphone: 1) == 32_685)
    #expect(FloatTrackMixer.mixedSample(system: -1, microphone: -1) == -32_685)
    #expect(FloatTrackMixer.mixedSample(system: 1, microphone: 1) != Int16.max)
}

@Test("A recovery rebuild and a normal mix agree sample for sample (F278)")
func recoveryAndCaptureMixesAgree() throws {
    // The real assertion: not that each path is self-consistent, but that the two paths produce the
    // same audio. This is what a divergence in the duplicated gain rule would break, and it is the
    // only test that would notice.
    //
    // **It was a tautology until F345.** It compared the two paths to each other and to nothing
    // else, so it passed whatever they both did — and what they both did was modulate the audio at
    // 31,992 gain flips per second, the most violently modulated fixture in this file, asserting
    // nothing about it. It now also checks both against a reference computed here from the raw
    // floats, so "they agree" cannot again mean "they are wrong together".
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }

    var system: [Float] = []
    var microphone: [Float] = []
    for index in 0..<2_000 {
        // Deliberately crossing every branch of the rule: both-active, solo, near-silence, and
        // sums past 1.0 that have to clamp.
        system.append(Float(sin(Double(index) * 0.05)) * 0.9)
        microphone.append(index % 3 == 0 ? 0.004 : Float(cos(Double(index) * 0.03)) * 0.7)
    }
    try fixture.write(system, to: fixture.system)
    try fixture.write(microphone, to: fixture.microphone)

    _ = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 2_000),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: 0, frameCount: 2_000),
        sampleRate: 48_000,
        outputURL: fixture.output
    )
    let captured = try pcmSamples(of: fixture.output)

    let rebuilt = try #require(
        try InterruptedRecordingRecovery.recover(in: fixture.directory, sampleRate: 48_000)
    )
    let recovered = try pcmSamples(of: rebuilt.recordingURL)

    let reference = zip(system, microphone).map {
        FloatTrackMixer.mixedSample(system: $0, microphone: $1)
    }
    #expect(captured.count == 2_000)
    #expect(recovered == captured, "the two mixing paths disagree")
    #expect(captured == reference, "both paths agree with each other and with neither the rule nor the audio")
}

@Test("An absurd presentation timestamp does not trap the mix (F151's lesson, third instance)")
func absurdPresentationTimeDoesNotTrapTheMix() throws {
    // `paddingFrames` did `Int64((firstPresentationTime - earliestStart) * sampleRate)`, and
    // `Int64(Double)` TRAPS on overflow. This is pre-existing code — F278 moved it here from
    // `AudioCaptureEngine` without looking at it — and it is the highest-consequence instance of
    // the three found today, because it runs during `stop()`. A trap here loses the entire meeting
    // at the moment it is being saved, which is worse than any wrong duration.
    //
    // A `CMTime` that decodes to something absurd is the realistic source: the mixer takes
    // whatever the capture recorded, and F151 has already established that presentation timestamps
    // are not to be trusted to be sane.
    let fixture = try MixFixture()
    defer { fixture.cleanUp() }
    try fixture.write([Float](repeating: 0.3, count: 8), to: fixture.system)
    try fixture.write([Float](repeating: 0.3, count: 8), to: fixture.microphone)

    let duration = try FloatTrackMixer.mix(
        system: FloatTrack(url: fixture.system, firstPresentationTime: 0, frameCount: 8),
        microphone: FloatTrack(url: fixture.microphone, firstPresentationTime: 1e18, frameCount: 8),
        sampleRate: 48_000,
        outputURL: fixture.output
    )

    // What it produces past the representable range is not the point — not crashing is. The
    // recording's own audio is still written, which is the guarantee that matters at stop time.
    #expect(duration > 0)
    #expect(FileManager.default.fileExists(atPath: fixture.output.path))
}

// MARK: - F345: the gain must not modulate the audio it is applied to

// The rule chose between 0.95 and 0.5 from the *instantaneous* sample, so a microphone waveform
// crossing ±0.01 — which it does twice per cycle — multiplied the system track by a square wave at
// roughly twice the microphone's dominant frequency. That is amplitude modulation, and its
// sidebands are the buzz reported on real captures: measured at −14.9 dBc against a −103 dBc
// quantization floor, i.e. ~88 dB of energy present in neither source.
//
// The assertion below is the time-domain statement of the same fault, and it is better than a
// spectral one: exact rather than thresholded, no DFT, and it states the defect in its own terms.
// A mix may attenuate its inputs; it may not add slope that is not in them.

/// 0.5 s at 48 kHz: a steady system tone under a microphone that crosses the old activity floor.
private func floorCrossingFixture(frames: Int = 24_000) -> (system: [Float], microphone: [Float]) {
    let rate = Float(48_000)
    let system = (0..<frames).map { 0.3 * sin(2 * .pi * 440 * Float($0) / rate) }
    let microphone = (0..<frames).map { 0.05 * sin(2 * .pi * 200 * Float($0) / rate) }
    return (system, microphone)
}

private func maximumStep(_ samples: [Int16]) -> Int {
    guard samples.count > 1 else { return 0 }
    return (1..<samples.count).map { abs(Int(samples[$0]) - Int(samples[$0 - 1])) }.max() ?? 0
}

@Test("The mix adds no slope that is not in the signals it mixes (F345)")
func theMixAddsNothingToTheSignalsOwnSlope() throws {
    let (system, microphone) = floorCrossingFixture()
    let mixed = zip(system, microphone).map { FloatTrackMixer.mixedSample(system: $0, microphone: $1) }
    // The reference: the same two signals mixed at a single constant gain. Any honest mix of these
    // inputs is at most this steep, because both are smooth sines an order of magnitude slower than
    // the sample rate.
    let linear = zip(system, microphone).map { expectedPCM(($0 + $1) * FloatTrackMixer.soloGain) }

    #expect(maximumStep(mixed) <= maximumStep(linear),
            "the mix moves faster than its own inputs do, so the extra movement is the gain switching, not the audio")
}

@Test("A one-LSB change in the input cannot move the output by more than one LSB (F345)")
func theMixIsLipschitzInItsInput() throws {
    // The same fault stated as a continuity bound, which is what a listener hears as a click.
    // Measured on the unfixed rule: a single-LSB input step moved the output by up to 4,570 LSB.
    let step = Float(1) / Float(Int16.max)
    var worst = 0
    var worstAt = Float(0)
    for microphone in [Float(0), 0.005, 0.02, 0.2] {
        var value = Float(-1.6)
        while value <= 1.6 {
            let here = FloatTrackMixer.mixedSample(system: value, microphone: microphone)
            let next = FloatTrackMixer.mixedSample(system: value + step, microphone: microphone)
            let moved = abs(Int(next) - Int(here))
            if moved > worst { worst = moved; worstAt = value }
            value += step
        }
    }
    #expect(worst <= 1, "a 1-LSB input step moved the output by \(worst) LSB near system=\(worstAt)")
}

@Test("A lone track passes through at exactly the solo gain, for every level (F345)")
func aLoneTrackIsUntouched() {
    // The loudness contract, promoted from a comment to a test. Below the knee the curve is exactly
    // `soloGain * sum`, so a solo passage is bit-identical to what the old rule produced — the fix
    // changes overlap, and nothing else.
    var mismatches = 0
    var value = Float(0)
    while value <= 1.0 {
        let expected = expectedPCM(value * FloatTrackMixer.soloGain)
        if FloatTrackMixer.mixedSample(system: value, microphone: 0) != expected { mismatches += 1 }
        if FloatTrackMixer.mixedSample(system: 0, microphone: value) != expected { mismatches += 1 }
        if FloatTrackMixer.mixedSample(system: -value, microphone: 0) != -expected { mismatches += 1 }
        value += 1.0 / 4096
    }
    #expect(mismatches == 0)
}

@Test("The mix is odd, monotone and never reaches full scale (F345)")
func theMixIsBoundedMonotoneAndOdd() {
    // Three properties that together say "this is a mix, not an effect": it cannot inject a DC
    // offset (odd), it cannot reorder loudness (monotone), and it cannot hard-clip (bounded).
    //
    // Monotone is the one the old rule broke, and the sweep holds the microphone ABOVE the old
    // activity floor so that it is actually exercised: with mic = 0.02, raising the system track
    // from 0.005 to 0.015 crossed the floor, flipped the gain 0.95 -> 0.5, and dropped the output
    // from 0.02375 to 0.0175 — a louder input producing a quieter sample. Sweeping with the
    // microphone at zero would never reach that branch and the assertion would be vacuous.
    let heldMicrophone: Float = 0.02
    var previous = Int16.min
    var nonMonotone = 0, unbounded = 0, notOdd = 0
    var sum = Float(-4)
    while sum <= 4 {
        let here = FloatTrackMixer.mixedSample(system: sum, microphone: heldMicrophone)
        if here < previous { nonMonotone += 1 }
        if here == Int16.max || here == Int16.min { unbounded += 1 }
        previous = here
        // Oddness is a property of the curve itself, so it is asked of the sum with nothing held.
        if FloatTrackMixer.mixedSample(system: -sum, microphone: 0)
            != -FloatTrackMixer.mixedSample(system: sum, microphone: 0) { notOdd += 1 }
        sum += 1.0 / 2048
    }
    #expect(nonMonotone == 0, "a louder input produced a quieter output")
    #expect(unbounded == 0, "the curve reached full scale, so it can clip")
    #expect(notOdd == 0, "the curve is asymmetric, which is a DC offset")
}

@Test("Loud overlap cannot clip at any level either track can hold (F345)")
func loudOverlapStillDoesNotClip() {
    // What the deleted 0.5 branch existed to prevent. Swept rather than sampled, because the old
    // rule's protection was conditional on both tracks exceeding a floor and this one is not.
    var clipped = 0
    var a = Float(0)
    while a <= 1.0 {
        var b = Float(0)
        while b <= 1.0 {
            let out = FloatTrackMixer.mixedSample(system: a, microphone: b)
            if out == Int16.max || out == Int16.min { clipped += 1 }
            b += 1.0 / 256
        }
        a += 1.0 / 256
    }
    #expect(clipped == 0, "\(clipped) full-scale samples from inputs inside [0, 1]")
}

@Test("Every chunk size produces the same audio, which is what keeps the two paths one rule (F345)")
func everyChunkingProducesTheSameAudio() throws {
    // `mixedSample` is a pure function of one frame, so chunking is free — and that is load-bearing
    // rather than incidental. `InterruptedRecordingRecovery.mixTracks` takes `chunkSize` as a
    // parameter: 8,192 in production, 100 in `RecoveryTruncationTests`. Any stateful gain rule would
    // have had to reproduce its state identically across both, and a per-chunk reset would click
    // every 8,192 frames in production while passing every test at 100.
    let frames = 8_192 * 4 + 7_265      // a short final chunk, deliberately not a multiple
    let system = (0..<frames).map { 0.6 * sin(2 * .pi * 440 * Float($0) / 48_000) }
    let microphone = (0..<frames).map { 0.5 * sin(2 * .pi * 197 * Float($0) / 48_000) }

    var renders: [[Int16]] = []
    for chunk in [1, 7, 100, 8_191, 8_192, 8_193] {
        var systemCursor = 0, microphoneCursor = 0
        var out: [Int16] = []
        _ = try InterruptedRecordingRecovery.mixTracks(
            totalFrames: Int64(frames),
            chunkSize: Int64(chunk),
            readSystem: { count in
                defer { systemCursor += count }
                return Array(system[systemCursor..<(systemCursor + count)])
            },
            readMicrophone: { count in
                defer { microphoneCursor += count }
                return Array(microphone[microphoneCursor..<(microphoneCursor + count)])
            },
            write: { out.append(contentsOf: $0) }
        )
        renders.append(out)
    }
    #expect(renders.allSatisfy { $0.count == frames })
    #expect(Set(renders.map { $0.map(String.init).joined(separator: ",") }).count == 1,
            "the mix depends on how it was chunked")
}
