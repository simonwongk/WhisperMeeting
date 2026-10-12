import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F942 — the mixer itself, on synthetic files: every channel of every track is summed, each at its own
// time, by the capture mixer's rule (0.95 of the sum, a limiter above full scale), into a 16 kHz mono
// 16-bit WAV. The recording is only read.

private func scratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Mixes `input` and returns the mix's samples, after checking it is 16 kHz mono 16-bit.
private func mixed(_ input: URL, in dir: URL) async throws -> (samples: [Float], result: RecordingMixer.Result) {
    let output = dir.appendingPathComponent("mix-\(UUID().uuidString).wav")
    let result = try await RecordingMixer.mixEveryChannel(of: input, to: output)
    let header = try #require(WAVInspection.header(at: output))
    #expect(header.channels == 1 && header.sampleRate == 16_000 && header.bitsPerSample == 16 && header.formatTag == 1)
    let decoded = try fixtureDecode(output)
    return (try #require(decoded.channels.first), result)
}

@Test("A track that starts later is heard from when it starts, not from the beginning (F942)")
func mixerPlacesEachTrackAtItsTime() async throws {
    let dir = try scratch("F942-late"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("late.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2)], seconds: 4),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 2, startSeconds: 2)])

    let (mix, result) = try await mixed(input, in: dir)

    #expect(result.tracks == 2 && result.channels == 2)
    #expect(abs(result.duration - 4) < 0.05)
    #expect(fixtureToneAmplitude(mix, rate: 16_000, frequency: 800, from: 0.2, to: 1.8) < 0.005)
    #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: 800, from: 2.2, to: 3.8) - 0.19) < 0.01)
    #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: 300, from: 0.2, to: 3.8) - 0.19) < 0.01)
}

@Test("Tracks whose sum passes full scale are limited, never clipped (F942)")
func mixerNeverClips() async throws {
    let dir = try scratch("F942-loud"); defer { try? FileManager.default.removeItem(at: dir) }
    // The same loud tone on both tracks: their sum peaks near 1.8.
    let input = dir.appendingPathComponent("loud.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.9)], seconds: 2),
                                             FixtureTrack(channels: [(300, 0.9)], seconds: 2)])

    let (mix, _) = try await mixed(input, in: dir)

    let peak = mix.reduce(Float(0)) { Swift.max($0, abs($1)) }
    #expect(peak < 0.999, "no sample reaches the rail: \(peak)")
    #expect(peak > 0.95, "and the sum is not turned down below where it fits: \(peak)")
}

@Test("A stereo track beside a mono one: each of the three channels is in the mix (F942)")
func mixerHearsAStereoTrackBesideAMonoOne() async throws {
    let dir = try scratch("F942-stereo"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("call.mp4")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2), (500, 0.2)], seconds: 3),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 3)])

    let (mix, result) = try await mixed(input, in: dir)

    #expect(result.tracks == 2 && result.channels == 3)
    for tone in [300.0, 500.0, 800.0] {
        #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: tone) - 0.19) < 0.01, "\(tone) Hz")
    }
}

@Test("What is mixed: not one track of one or two channels, nor alternates; poly WAVs and several tracks are (F942)")
func mixerDecidesFromTheFile() async throws {
    let dir = try scratch("F942-decide"); defer { try? FileManager.default.removeItem(at: dir) }
    let mono = dir.appendingPathComponent("mono.wav")
    try WAVWriter.wavData(from: fixtureTone(frequency: 440, amplitude: 0.3, seconds: 1), sampleRate: 48_000).write(to: mono)
    let poly = dir.appendingPathComponent("poly.wav")
    try fixturePolyWAV([300.0, 500.0, 700.0].map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 1) }).write(to: poly)
    let two = dir.appendingPathComponent("two.m4a")
    try await writeFixtureTracks(to: two, [FixtureTrack(channels: [(300, 0.2)], seconds: 1),
                                           FixtureTrack(channels: [(800, 0.2)], seconds: 1)])
    let languages = dir.appendingPathComponent("languages.mov")
    try await writeFixtureTracks(to: languages, [FixtureTrack(channels: [(300, 0.2)], seconds: 1),
                                                 FixtureTrack(channels: [(800, 0.2)], seconds: 1)],
                                 alternates: true, languages: ["eng", "fra"])
    let grouped = dir.appendingPathComponent("grouped.mp4")
    try await writeFixtureTracks(to: grouped, [FixtureTrack(channels: [(300, 0.2)], seconds: 1),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 1)], alternates: true)

    #expect(await RecordingMixer.decision(for: mono) == .asItIs)
    #expect(await RecordingMixer.decision(for: poly) == .mixEveryChannel(channels: 3))
    #expect(await RecordingMixer.decision(for: two) == .mixEveryChannel(channels: 2))
    #expect(await RecordingMixer.decision(for: languages) == .unsupported(.alternateTracks(count: 2)))
    #expect(await RecordingMixer.decision(for: grouped) == .mixEveryChannel(channels: 2), "a group without languages, as ffmpeg writes")
    #expect(await RecordingMixer.decision(for: dir.appendingPathComponent("missing.mov")) == .asItIs,
            "what AVFoundation cannot read is left to the engines, as before")
    // Alternates are never summed, and nothing is left behind.
    let output = dir.appendingPathComponent("refused.wav")
    await #expect(throws: RecordingMixer.Failure.notMixable(.alternateTracks(count: 2))) {
        _ = try await RecordingMixer.mixEveryChannel(of: languages, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try await RecordingMixer.mixIfNeeded(languages, into: dir) == nil, "the engines keep the default track")
}
