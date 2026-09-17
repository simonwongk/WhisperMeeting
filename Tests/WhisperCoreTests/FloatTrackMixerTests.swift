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

@Test("Two active tracks are summed at half gain, so a mix cannot clip (F278)")
func bothActiveTracksMixAtHalfGain() throws {
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

    // 0.8 + 0.6 = 1.4 summed straight would clip hard; at 0.5 it lands at 0.7.
    let samples = try pcmSamples(of: fixture.output)
    #expect(samples.count == 16)
    #expect(samples.allSatisfy { $0 == expectedPCM(0.7) })
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

@Test("The 0.01 activity floor keeps dither from halving a real track (F278)")
func nearSilenceCountsAsInactive() throws {
    // `abs(sample) > 0.01` on both sides is what selects the 0.5 path. A track carrying only noise
    // must not trip it, or one participant's room hiss would quietly halve the other's voice.
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
    #expect(Array(samples[4..<8]).allSatisfy { $0 == expectedPCM(1.0 * 0.5) })
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
    #expect(samples.allSatisfy { $0 == expectedPCM(0.8 * 0.5) },
            "a chunk boundary changed the mix")
}

// MARK: - The gain rule, which existed in three copies (F278)

// A correction to F278's own text, and to the review it came from: the claim was "three copies of
// the WAV header builder". That was wrong — there were two, because `FloatTrackMixer` already called
// `WAVWriter.header`. But there really are three copies of the *mixing* arithmetic, and one of them
// hid behind the miscount: the capture mixer, the recovery rebuild
// (`InterruptedRecordingRecovery.swift:146-153`), and — before F278 — the engine's private copy.
//
// The numbers 0.01 / 0.5 / 0.95 are a judgement about how two microphones sum. Two independent
// copies of a judgement drift, and the divergence would be audible in exactly one of the two paths:
// the one that runs after a recording was interrupted, where nobody has the original to compare to.

@Test("The gain rule is one function, and it is the rule the mixer applies (F278)")
func gainRuleIsSharedAndCorrect() {
    #expect(FloatTrackMixer.mixedSample(system: 0.8, microphone: 0.6) == expectedPCM(1.4 * 0.5))
    #expect(FloatTrackMixer.mixedSample(system: 0.5, microphone: 0) == expectedPCM(0.5 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: 0.5) == expectedPCM(0.5 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0.005, microphone: 0.5)
        == expectedPCM(0.505 * 0.95))
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: 0) == 0)

    // Clamped, not wrapped: two loud tracks summing past 1.0 must saturate rather than overflow
    // `Int16` into the opposite sign, which would be a loud click instead of a quiet clip.
    #expect(FloatTrackMixer.mixedSample(system: 1, microphone: 1) == expectedPCM(1.0))
    #expect(FloatTrackMixer.mixedSample(system: -1, microphone: -1) == expectedPCM(-1.0))
}

@Test("A recovery rebuild and a normal mix agree sample for sample (F278)")
func recoveryAndCaptureMixesAgree() throws {
    // The real assertion: not that each path is self-consistent, but that the two paths produce the
    // same audio. This is what a divergence in the duplicated gain rule would break, and it is the
    // only test that would notice.
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

    #expect(captured.count == 2_000)
    #expect(recovered == captured, "the two mixing paths disagree")
}
