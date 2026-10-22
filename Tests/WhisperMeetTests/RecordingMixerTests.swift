import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F942 — the mixer itself, on synthetic files: each track's channels are averaged, each track placed at its
// own time, and the tracks summed by the capture mixer's rule (0.95 of the sum, a limiter above full scale),
// into a 16 kHz mono 16-bit WAV. The recording is only read.

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

// Second review of F942, N16: the bound on a buffer's time is the tracks' own time range, and an edit list
// sets that range, so an edit list placing a track an hour in made a 108 KB file mix into a 115 MB WAV, and
// the gap before it was handed on as one allocation the size of the gap. Kept small here: two 1 s tracks,
// the second placed 300 s in, which mixed into 301 s (9.6 MB).
@Test("Tracks timed to run far past the audio they hold are refused, not padded with silence (F942 second review)")
func mixerRefusesSilenceFarPastTheAudioHeld() async throws {
    let dir = try scratch("F942-editlist"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("offset.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2)], seconds: 1),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 1, startSeconds: 300)])
    let output = dir.appendingPathComponent("mix.wav")

    do {
        let result = try await RecordingMixer.mixEveryChannel(of: input, to: output)
        Issue.record("mixed \(result.duration) s from 2 s of audio")
    } catch {
        #expect(error.localizedDescription.contains("hold only"), "\(error.localizedDescription)")
    }
    #expect(!FileManager.default.fileExists(atPath: output.path), "nothing is left of a refused mix")
}

@Test("A gap no track covers, within the bound, is mixed as silence handed on a few seconds at a time (F942 second review)")
func mixerHandsALongGapOnInChunks() async throws {
    let dir = try scratch("F942-gap"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("gap.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2)], seconds: 1),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 1, startSeconds: 30)])
    let asset = AVURLAsset(url: input)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let end = try await RecordingMixer.audioEnd(of: tracks)

    var longest = 0, total = 0
    _ = try RecordingMixer.readInStep(asset: asset, tracks: tracks, channels: [1, 1], audioEnd: end) { start, count, _ in
        #expect(start == total, "in order, with nothing skipped")
        longest = Swift.max(longest, count)
        total += count
    }

    #expect(abs(Double(total) / 16_000 - 31) < 0.05, "\(total) frames")
    // Four seconds at most. This held before the chunking too: AVAssetReader hands an edit list's empty edit
    // back as silence buffers of its own, at most 8,192 frames each here (measured). The chunking bounds a gap
    // between a track's own buffers, which AVAssetWriter does not write (it closes one), so no file here has it.
    #expect(longest <= 64_000, "\(longest) frames in one stretch")
    let (mix, _) = try await mixed(input, in: dir)
    #expect(fixtureToneAmplitude(mix, rate: 16_000, frequency: 800, from: 5, to: 25) < 0.005)
    #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: 800, from: 30.1, to: 30.9) - 0.19) < 0.01)
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

// Review of F942: a capture averages a track's channels (F659) and then sums its tracks; the mixer summed
// every channel, so a stereo track holding one voice on both sides came out twice as loud beside another
// track as on every other path (0.57 for 0.3), and was driven into the limiter's knee from 0.5 up.
@Test("A stereo track beside another track is as loud as it is alone: a track's channels are averaged (F942 review)")
func mixerAveragesATracksChannels() async throws {
    let dir = try scratch("F942-average"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("dual-mono.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.3), (300, 0.3)], seconds: 3),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 3, audibleFrom: 2)])

    let (mix, _) = try await mixed(input, in: dir)

    // 0.95 of the voice's own level, as a capture's limiter rule gives a lone track; summed, it read 0.57.
    #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: 300, from: 0.2, to: 1.8) - 0.285) < 0.01)
    #expect(mix.filter { abs($0) > 0.5 }.isEmpty, "nowhere near the limiter")
}

// F964 — a segment re-run decodes a WAV with more than two channels by averaging them (`decodedSegmentClip`,
// F581), while round 1 of F942 summed them for the full transcription, so a re-run line on a four-microphone
// recording was 12 dB quieter than what transcribed the meeting. Averaging a track's channels in the mix
// (review of F942) puts both at the same level, to the capture's 0.95.
@Test("A segment re-run of a four-channel WAV hears each channel as loud as the full transcription did (F964)")
@MainActor
func segmentClipIsAsLoudAsTheMixOfAPolyWAV() async throws {
    let dir = try scratch("F964"); defer { try? FileManager.default.removeItem(at: dir) }
    let tones = [300.0, 500.0, 700.0, 900.0]
    let input = dir.appendingPathComponent("recording.wav")
    try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 4) }).write(to: input)

    let (mix, _) = try await mixed(input, in: dir)
    let clipURL = try AppModel.makeSegmentClip(from: input, startSeconds: 1, endSeconds: 3)
    defer { AppModel.removeSegmentClip(clipURL) }
    let clip = try fixtureDecode(clipURL)
    let clipSamples = try #require(clip.channels.first)

    for tone in tones {
        let full = fixtureToneAmplitude(mix, rate: 16_000, frequency: tone, from: 1.2, to: 2.8)
        let rerun = fixtureToneAmplitude(clipSamples, rate: clip.rate, frequency: tone, from: 0.2, to: 1.8)
        // 0.05 in the clip (0.2 averaged over four), 0.0475 in the mix; summed, the mix read 0.19.
        #expect(full > 0.04 && rerun / full > 0.9 && rerun / full < 1.2, "\(tone) Hz: full run \(full), re-run \(rerun)")
    }
}

@Test("A stereo track beside a mono one: each of the three channels is in the mix (F942)")
func mixerHearsAStereoTrackBesideAMonoOne() async throws {
    let dir = try scratch("F942-stereo"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("call.mp4")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2), (500, 0.2)], seconds: 3),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 3)])

    let (mix, result) = try await mixed(input, in: dir)

    #expect(result.tracks == 2 && result.channels == 3)
    // The stereo track's two sides averaged into its own signal (0.2 / 2), the mono track whole, at 0.95.
    for (tone, level) in [(300.0, 0.095), (500.0, 0.095), (800.0, 0.19)] {
        #expect(abs(fixtureToneAmplitude(mix, rate: 16_000, frequency: tone) - level) < 0.008, "\(tone) Hz")
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

// F998 — the mix keeps its own read for Shrink's audit: every channel as it was summed, so the audit fits the
// copy against the samples the copy was made from, not a second read AVAssetReader lines up differently.
@Test("The mix keeps the very samples it summed: its kept read, weighted and summed, is the mix (F998)")
func mixerKeepsTheReadItSummed() async throws {
    let dir = try scratch("F998-lanes"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("call.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2), (500, 0.1)], seconds: 9),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 8.5, startSeconds: 0.5)])
    let output = dir.appendingPathComponent("mix.wav")
    let lanes = RecordingMixer.lanes(beside: output)

    let result = try await RecordingMixer.mixEveryChannel(of: input, to: output, lanes: lanes)

    #expect(result.lanes == lanes && result.trackChannels == [2, 1] && result.frames > 0)
    let mix = try #require(try fixtureDecode(output).channels.first)
    var kept = [[Float]](repeating: [], count: 3)
    var stretches = 0
    let frames = try RecordingMixer.replay(lanes: lanes, trackChannels: result.trackChannels) { start, count, stretch in
        #expect(start == kept[0].count && stretch.map(\.count) == [2, 1] && stretch.joined().allSatisfy { $0.count == count })
        for (channel, samples) in stretch.joined().enumerated() { kept[channel] += samples }
        stretches += 1
    }
    #expect(frames == mix.count && frames == result.frames && abs(frames - 144_000) < 1_600,
            "every frame of the mix, and no more: \(frames), \(mix.count), \(result.frames)")
    #expect(stretches == 3, "replayed at most four seconds at a time: \(stretches)")
    // The capture's rule over the kept channels: 0.95 of the stereo track's average plus the mono track,
    // each frame within the 16-bit step of the mix. Nowhere near the limiter at these levels.
    var worst: Float = 0
    for t in 0..<frames {
        let summed: Float = 0.95 * ((kept[0][t] + kept[1][t]) / 2 + kept[2][t])
        worst = max(worst, abs(summed - mix[t]))
    }
    #expect(worst < 2 / 32_768, "the kept read is what was summed: \(worst)")
    // Kept where the mixer placed it: the late track is silent for its first half second.
    #expect(kept[2][..<7_900].allSatisfy { abs($0) < 1e-6 } && kept[2][8_100...].contains { abs($0) > 0.1 })
}

// Review of F998, finding 2: a kept read that is not the whole read — no channels, or fewer frames than the
// mix holds — measured an audit of no windows, or none past where it stopped, and an audit of no windows
// finds nothing wrong. Now it is refused, and Shrink keeps the original.
@Test("An audit against a kept read short of the mix, or of no channels, is refused, not measured as far as it goes (F998 review)")
func keptReadAuditRefusesAReadThatIsNotTheMixs() async throws {
    let dir = try scratch("F998-short"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("call.mov")
    try await writeFixtureTracks(to: input, [FixtureTrack(channels: [(300, 0.2)], seconds: 3),
                                             FixtureTrack(channels: [(800, 0.2)], seconds: 3)])
    let output = dir.appendingPathComponent("mix.wav")
    let lanes = RecordingMixer.lanes(beside: output)
    let result = try await RecordingMixer.mixEveryChannel(of: input, to: output, lanes: lanes)

    // The whole read, against the mix itself (16 kHz mono, as a copy is): measured, window by window.
    let whole = try RecordingMixer.audit(lanes: lanes, trackChannels: result.trackChannels, frames: result.frames, against: output)
    #expect(whole.windows.count == 3)
    #expect(RecordingMixPlan.firstFinding(whole, nativeChannelWindows: [], nativeLevel: 0.1) == nil)
    // No channels, or no frames: nothing to measure against.
    #expect(throws: RecordingMixer.Failure.self) {
        _ = try RecordingMixer.audit(lanes: lanes, trackChannels: [], frames: result.frames, against: output)
    }
    #expect(throws: RecordingMixer.Failure.self) {
        _ = try RecordingMixer.audit(lanes: lanes, trackChannels: result.trackChannels, frames: 0, against: output)
    }
    // A read cut short of the mix, a whole second off its end.
    let handle = try FileHandle(forWritingTo: lanes)
    try handle.truncate(atOffset: UInt64((result.frames - 16_000) * 2 * MemoryLayout<Float>.size))
    try handle.close()
    #expect(throws: RecordingMixer.Failure.self) {
        _ = try RecordingMixer.audit(lanes: lanes, trackChannels: result.trackChannels, frames: result.frames, against: output)
    }
}

// F1072, F1073 — the premise of `RecordingMixPlan.readAgreementBand`: two reads of a file, the mixer's kept one
// and one of its own lined up with it, agree on every channel's level per second far inside 10 %, though
// AVAssetReader lines them up a frame or two apart. Measured on the layouts whose reads F998 found out of step;
// these AVAssetWriter fixtures do not drift (`readsComparedFollowsADriftingSecondRead` does).
@Test("Two reads of a recording, lined up, agree on each channel's level per second far inside the band (F1072, F1073)")
func twoReadsAgreeOnEveryChannelsLevel() async throws {
    let dir = try scratch("F1072-reads"); defer { try? FileManager.default.removeItem(at: dir) }
    // Plain loops with typed parts: one expression summing these inside a closure was more than the runner's
    // Swift 6.1 would type-check in time (CI run on e45d69ab), though the developer's newer compiler took it.
    func voice(_ base: Double, from: Double = 0) -> [Float] {
        var samples = [Float](repeating: 0, count: 8 * 48_000)
        for n in samples.indices {
            let t: Double = Double(n) / 48_000
            guard t >= from else { continue }
            var sum: Double = 0
            for k in 0..<8 {
                let tone: Double = sin(2 * Double.pi * base * Double(k + 1) * 1.37 * t)
                let swell: Double = 0.55 + 0.45 * sin(2 * Double.pi * (2 + Double(k)) * t)
                sum += 0.03 * tone * swell
            }
            samples[n] = Float(sum)
        }
        return samples
    }
    let a = voice(311), b = voice(353, from: 3)
    let layouts: [(String, [[[Float]]])] = [
        ("identical tracks", [[a], [a]]),
        ("dual-mono track + mono track", [[a, a], [b]]),
        ("OBS: master + microphone + desktop", [[zip(a, b).map { $0 + $1 }], [a], [b]]),
    ]
    for (label, tracks) in layouts {
        let input = dir.appendingPathComponent("\(UUID().uuidString).mov")
        try await writeFixtureRawTracks(to: input, tracks)
        let output = dir.appendingPathComponent("\(UUID().uuidString).wav")
        let lanes = RecordingMixer.lanes(beside: output)
        let result = try await RecordingMixer.mixEveryChannel(of: input, to: output, lanes: lanes)
        let reads = try await RecordingMixer.readsCompared(of: input, lanes: lanes, trackChannels: result.trackChannels, frames: result.frames)
        #expect(reads.kept.levels.count == reads.again.levels.count && reads.kept.frames == reads.again.frames, "\(label)")
        var worst = 0.0
        for (k, g) in zip(reads.kept.levels, reads.again.levels) {
            for (kv, gv) in zip(k, g) where gv > 0.005 { worst = max(worst, abs(kv / gv - 1)) }
        }
        #expect(worst < 0.02, "\(label): the reads' levels differ by up to \(worst)")
        #expect(RecordingMixPlan.firstReadDisagreement(kept: reads.kept, again: reads.again) == nil, "\(label)")
    }
}

// F1073 — review 2 of F998, finding 1: two reads of an ffmpeg-made file drift apart about 0.4 frames a second
// without bound, and F1072 compared their levels at the same window edges, where a sound starting near an edge
// moves between windows. In memory, so the drift is exact: a minute of two tracks, the second read of track 1
// drifting 4 frames a second and of track 2 10 frames a second (faster than any file measured, so a minute
// shows what an hour would), track 2 a burst every other second starting 40 ms before a window's edge — so
// that window holds the onset alone, and what drifts out of it is not made up by what drifts in.
@Test("A second read that drifts from the kept one is lined up before levels are compared; a loss is still refused (F1073)")
func readsComparedFollowsADriftingSecondRead() throws {
    let dir = try scratch("F1073-drift"); defer { try? FileManager.default.removeItem(at: dir) }
    let rate = 16_000, total = 60 * rate
    var seed: UInt32 = 12_345
    func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
    var voice = [Float](repeating: 0, count: total)  // typed loops, for the runner's Swift 6.1 (see above)
    for n in voice.indices {
        let t: Double = Double(n) / Double(rate)
        var sum: Double = 0
        for k in 0..<8 {
            let tone: Double = sin(2 * Double.pi * 311 * Double(k + 1) * 1.37 * t)
            let swell: Double = 0.55 + 0.45 * sin(2 * Double.pi * (2 + Double(k)) * t)
            sum += 0.03 * tone * swell
        }
        voice[n] = Float(sum)
    }
    var bursts = [Float](repeating: 0, count: total)
    for n in bursts.indices {
        let into: Double = Double(n % (2 * rate)) / Double(rate)
        if into >= 0.96 && into < 1.30 { bursts[n] = 0.2 * noise() }
    }
    func drifting(_ samples: [Float], framesPerSecond: Int) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        for n in samples.indices where n - n * framesPerSecond / rate >= 0 { out[n] = samples[n - n * framesPerSecond / rate] }
        return out
    }
    let again = [drifting(voice, framesPerSecond: 4), drifting(bursts, framesPerSecond: 10)]
    func keptFile(_ tracks: [[Float]]) throws -> URL {
        var interleaved = [Float](repeating: 0, count: total * tracks.count)
        for (channel, samples) in tracks.enumerated() { for n in 0..<total { interleaved[n * tracks.count + channel] = samples[n] } }
        let url = dir.appendingPathComponent("\(UUID().uuidString).lanes")
        try interleaved.withUnsafeBytes { Data($0) }.write(to: url)
        return url
    }
    let readAgain: RecordingMixer.StretchRead = { body in
        var start = 0
        while start < total {
            let count = min(4_096, total - start)
            try body(start, count, again.map { [Array($0[start..<(start + count)])] })
            start += count
        }
        return total
    }
    // F1072's comparison, the windows' levels at the same edges: the drift reads as a disagreement.
    func unaligned(_ tracks: [[Float]]) -> RecordingMixPlan.ChannelLevels {
        let windows = (total + rate - 1) / rate
        var levels: [[Double]] = []
        for samples in tracks {
            var row: [Double] = []
            for w in 0..<windows {
                var squares: Double = 0
                for n in (w * rate)..<min(total, (w + 1) * rate) { squares += Double(samples[n]) * Double(samples[n]) }
                row.append((squares / Double(min(total, (w + 1) * rate) - w * rate)).squareRoot())
            }
            levels.append(row)
        }
        return RecordingMixPlan.ChannelLevels(levels: levels, frames: [Double](repeating: Double(rate), count: windows), sampleRate: Double(rate))
    }
    let atTheSameEdges = RecordingMixPlan.firstReadDisagreement(kept: unaligned([voice, bursts]), again: unaligned(again))
    #expect(atTheSameEdges != nil, "the drift is large enough to show the problem")

    let lined = try RecordingMixer.readsCompared(lanes: try keptFile([voice, bursts]), trackChannels: [1, 1], frames: total, again: readAgain)
    #expect(lined.kept.frames.count == 60)
    #expect(RecordingMixPlan.firstReadDisagreement(kept: lined.kept, again: lined.again) == nil, "lined up, the two reads agree")
    var worst = 0.0
    for (k, g) in zip(lined.kept.levels, lined.again.levels) { for (kv, gv) in zip(k, g) where gv > 0.005 { worst = max(worst, abs(kv / gv - 1)) } }
    // One lag serves a window, and at 10 frames a second the lag moves that much inside one: measured 1.4 %
    // (real reads drift 0.4 frames a second, 25 times less), well inside the band's 10 %.
    #expect(worst < 0.05, "lined up, levels differ by up to \(worst)")

    // The kept read lost the 300 ms of the burst at 31.0–31.3 s: refused in window 31, on channel 2.
    var lost = bursts
    for n in (31 * rate)..<(31 * rate + 4_800) { lost[n] = 0 }
    let losing = try RecordingMixer.readsCompared(lanes: try keptFile([voice, lost]), trackChannels: [1, 1], frames: total, again: readAgain)
    #expect(RecordingMixPlan.firstReadDisagreement(kept: losing.kept, again: losing.again) == .readsDisagree(window: 31, channel: 1))

    // A second read that stopped half a second short, more than a drift explains, is not one to hold the kept
    // read to: past its end nothing would be compared.
    let shortRead: RecordingMixer.StretchRead = { body in
        let end = total - 8_000
        var start = 0
        while start < end {
            let count = min(4_096, end - start)
            try body(start, count, again.map { [Array($0[start..<(start + count)])] })
            start += count
        }
        return end
    }
    #expect(throws: RecordingMixer.Failure.self) {
        _ = try RecordingMixer.readsCompared(lanes: try keptFile([voice, bursts]), trackChannels: [1, 1], frames: total, again: shortRead)
    }
}

// F1073 — review 2 of F998 asked for this before mixing Shrink is switched on: a long ffmpeg-made multi-track
// file, whose reads drift apart (F980's log), read twice through the mixer. Opt in (it needs ffmpeg, which
// the CI runner does not have, and takes minutes): F1073_FFMPEG_DRIFT=1, and optionally F1073_MINUTES.
// Two tracks of gated pink noise whose onsets fall at every phase of the one-second windows (periods 1.7 s
// and 2.3 s), encoded by ffmpeg to AAC in one .mov.
@Test("A long ffmpeg-made two-track file: its two reads, lined up, agree on every level; at the same window edges they need not (F1073)",
      .enabled(if: ProcessInfo.processInfo.environment["F1073_FFMPEG_DRIFT"] == "1"))
func longFFmpegFileReadsAgreeLinedUp() async throws {
    let dir = try scratch("F1073-ffmpeg"); defer { try? FileManager.default.removeItem(at: dir) }
    let minutes = Int(ProcessInfo.processInfo.environment["F1073_MINUTES"] ?? "") ?? 30
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    let tool = try #require(ffmpeg, "ffmpeg is not installed")
    let input = dir.appendingPathComponent("two-track.mov")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["-v", "error", "-y",
                         "-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:amplitude=0.3:seed=7:duration=\(minutes * 60)",
                         "-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:amplitude=0.2:seed=11:duration=\(minutes * 60)",
                         "-filter_complex", "[0]volume='if(gt(mod(t,1.7),0.9),1,0)':eval=frame[a];[1]volume='if(gt(mod(t,2.3),1.1),1,0)':eval=frame[b]",
                         "-map", "[a]", "-map", "[b]", "-c:a", "aac", "-b:a", "128k", input.path]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "ffmpeg failed")

    // Two reads, each the mixer's own, each kept beside its mix.
    var kept: [(lanes: URL, result: RecordingMixer.Result)] = []
    for _ in 0..<2 {
        let output = dir.appendingPathComponent("\(UUID().uuidString).wav")
        let lanes = RecordingMixer.lanes(beside: output)
        kept.append((lanes, try await RecordingMixer.mixEveryChannel(of: input, to: output, lanes: lanes)))
    }
    let first = kept[0], second = kept[1]
    #expect(first.result.trackChannels == second.result.trackChannels)
    let frames = min(first.result.frames, second.result.frames)
    let secondRead: RecordingMixer.StretchRead = { body in
        try RecordingMixer.replay(lanes: second.lanes, trackChannels: second.result.trackChannels, body: body)
    }
    let lined = try RecordingMixer.readsCompared(lanes: first.lanes, trackChannels: first.result.trackChannels, frames: frames, again: secondRead)
    var linedWorst = 0.0
    var linedOff: [String] = []
    for (c, (k, g)) in zip(lined.kept.levels, lined.again.levels).enumerated() {
        for (w, (kv, gv)) in zip(k, g).enumerated() where gv > 0.01 {
            linedWorst = max(linedWorst, abs(kv / gv - 1))
            if abs(kv / gv - 1) > 0.01 { linedOff.append("ch\(c) w\(w) \(kv / gv) over \(lined.kept.frames[w]) frames") }
        }
    }
    print("F1073 ffmpeg windows lined up more than 1 % apart: \(linedOff.count) — \(linedOff.prefix(8))")
    // At the same window edges, as F1072 compared them: each read's own levels, unshifted.
    func unshifted(_ read: (lanes: URL, result: RecordingMixer.Result)) throws -> RecordingMixPlan.ChannelLevels {
        let channels = read.result.trackChannels.reduce(0, +)
        var squares = [[Double]](repeating: [], count: channels)
        var counts: [Double] = []
        _ = try RecordingMixer.replay(lanes: read.lanes, trackChannels: read.result.trackChannels) { start, count, stretch in
            let flat = stretch.flatMap { $0 }
            for k in 0..<count where start + k < frames {
                let window = (start + k) / 16_000
                while counts.count <= window { counts.append(0); for c in 0..<channels { squares[c].append(0) } }
                counts[window] += 1
                for c in 0..<channels { squares[c][window] += Double(flat[c][k]) * Double(flat[c][k]) }
            }
        }
        var levels: [[Double]] = []
        for row in squares { levels.append(zip(row, counts).map { ($0 / $1).squareRoot() }) }
        return RecordingMixPlan.ChannelLevels(levels: levels, frames: counts, sampleRate: 16_000)
    }
    let a = try unshifted(first), b = try unshifted(second)
    var edgeWorst = 0.0
    for (k, g) in zip(a.levels, b.levels) { for (kv, gv) in zip(k, g) where gv > 0.01 { edgeWorst = max(edgeWorst, abs(kv / gv - 1)) } }
    print("F1073 ffmpeg \(minutes) min: lined up worst \(linedWorst), finding \(String(describing: RecordingMixPlan.firstReadDisagreement(kept: lined.kept, again: lined.again))); same edges worst \(edgeWorst), finding \(String(describing: RecordingMixPlan.firstReadDisagreement(kept: a, again: b)))")
    #expect(RecordingMixPlan.firstReadDisagreement(kept: lined.kept, again: lined.again) == nil)
}
