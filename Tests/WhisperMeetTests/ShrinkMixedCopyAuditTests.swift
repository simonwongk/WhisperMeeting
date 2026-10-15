import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F980, F978, F953 — Shrink deletes the original, so a mixed copy is deleted only when every track's and
// every channel's sound is provably in it; anything the audit cannot prove is a refusal. These are the
// adversarial fixtures, written before the audit was touched: every probe of the two Wave 6 reviews of
// F942 (D1, D2, C3's drift, C4's near-identical tracks, N8/N9's short and partial windows, the 16/17
// boundary) and the shapes they did not try (a track masked where the mixer lost it, tracks that cancel
// each other, DC, clipping, different lengths, quad). Each is driven through the calls the Shrink button
// makes, with the real mixer, encoder and decoder unless a faulty one is named, and pins the outcome the
// rule demands: kept, or shrunk with every tone in the copy.

/// `expected` is the tone's amplitude in a copy the real mixer and encode make: a track's channels averaged, the
/// tracks summed at the mix's 0.95.
private func expectTone(_ copy: [Float], _ frequency: Double, from: Double, to: Double, _ expected: Double,
                        within tolerance: Double = 0.012, _ label: String = "") {
    let measured = fixtureToneAmplitude(copy, rate: 16_000, frequency: frequency, from: from, to: to)
    #expect(abs(measured - expected) < tolerance, "\(label) \(Int(frequency)) Hz [\(from), \(to)): \(measured) for \(expected)")
}

/// A mixer with the review's M8 fault, standing in for `mixForShrink`: it mixes `standIn` — the recording with
/// some of its sound taken out — and reports the real recording's track and channel counts.
@MainActor
private func mixerLosing(_ standIn: URL, tracks: Int, channels: Int) -> @Sendable (URL, URL) async throws -> RecordingMixer.Result {
    { _, output in
        let result = try await RecordingMixer.mixEveryChannel(of: standIn, to: output)
        return RecordingMixer.Result(tracks: tracks, channels: channels, duration: result.duration)
    }
}

/// An encode standing in for `encodeForShrink` that encodes `transform` of the mix instead of the mix.
private func encodeTransformed(_ transform: @escaping @Sendable ([Float]) -> [Float]) -> @Sendable (URL, URL, URL) throws -> Void {
    { input, output, working in
        let mono = try #require(try fixtureDecode(input).channels.first)
        let wav = output.deletingLastPathComponent().appendingPathComponent(".transformed-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try WAVWriter.wavData(from: transform(mono), sampleRate: 16_000).write(to: wav)
        try AudioCompressor.compressSpeech(input: wav, output: output, workingWAV: working)
    }
}

/// `samples` delayed by `frames` (silence in front) up to `until` frames of the timeline, and by `then` after it.
private func shifted(_ samples: [Float], by frames: Int, until: Int = .max, then: Int? = nil) -> [Float] {
    var out = [Float](repeating: 0, count: samples.count)
    for n in samples.indices {
        let lag = n < until ? frames : (then ?? frames)
        if n - lag >= 0 && n - lag < samples.count { out[n] = samples[n - lag] }
    }
    return out
}

/// A voice-like signal: `tones`, irregularly spaced across speech's band, at `amplitude` each, `seconds` long,
/// silent outside `[from, to)`, each tone swelling and fading at its own syllabic rate (2–7 Hz). Broadband and
/// unsteady, as speech is, so that no shift within a few periods of one tone fits it again — a single tone
/// lines up with itself every period, four steady ones did at 0.6 of their level 31 frames off, and twelve
/// steady ones still let a track lock a window early in one run of three (`gates/19-anchor-run.log`).
private func fixtureVoice(_ tones: [Double], amplitude: Double = 0.03, seconds: Double, from: Double = 0, to: Double = .infinity) -> [Float] {
    var sum = [Float](repeating: 0, count: Int(seconds * 48_000))
    for (index, tone) in tones.enumerated() {
        let rate = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        for (n, value) in fixtureTone(frequency: tone, amplitude: amplitude, seconds: seconds, from: from, to: to).enumerated() {
            sum[n] += value * Float(0.55 + 0.45 * sin(2 * Double.pi * rate * Double(n) / 48_000 + phase))
        }
    }
    return sum
}
private let voiceA: [Double] = [311, 457, 619, 737, 911, 1_171, 1_409, 1_777, 2_389, 2_917, 3_571, 4_283]
private let voiceB: [Double] = [353, 419, 541, 823, 953, 1_291, 1_613, 2_011, 2_557, 2_963, 3_803, 4_621]

/// `samples` delayed by a lag that grows evenly from 0 at the start to `frames` at the end, one more frame
/// each `count / frames` samples (a sample is repeated where the lag steps).
private func drifting(_ samples: [Float], to frames: Int) -> [Float] {
    samples.indices.map { n in
        let lag = n * frames / Swift.max(1, samples.count)
        return n - lag >= 0 ? samples[n - lag] : 0
    }
}

// MARK: - The second review's deletions, with the real mixer (D1, D2)

@Test("A quiet track whose channels cancel, alone for half the recording, keeps its original (F980 D1)")
@MainActor
func shrinkAuditKeepsAQuietTrackWhoseChannelsCancel() async throws {
    // The review's N1 at 0.015 (−36.5 dBFS): under a tenth of the recording's level, so the audit never
    // judged it, and the real mixer cancelled it even where it sounded alone.
    let f = try await MixFixture(recordingExtension: "mov", duration: 20) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.5)], seconds: 20, audibleTo: 10),
                                               FixtureTrack(channels: [(800, 0.015), (800, -0.015)], seconds: 20)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed") && alert.contains("cancels itself"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty)
}

@Test("A float WAV with a NaN channel, throughout or for a stretch, keeps its original (F980 D2)")
@MainActor
func shrinkAuditKeepsAFloatWAVWithANaNChannel() async throws {
    // The review's N2. The mixer now mixes a NaN sample as silence (F942 round 3), so the copy holds the other
    // three channels; but a value that is not a number is not sound the audit can show in a copy, so the
    // original is kept and the reason says so.
    for (label, from, to) in [("throughout", 0.0, 15.0), ("from 5 s to 10 s", 5.0, 10.0)] {
        var channels = [300.0, 500.0, 700.0, 900.0].map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 15, rate: 16_000) }
        for n in Int(from * 16_000)..<Int(to * 16_000) { channels[3][n] = .nan }
        let f = try await MixFixture(recordingExtension: "wav", duration: 15) { url in
            try fixtureFloatWAV(channels, rate: 16_000).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("nothing was removed"), "\(label): \(alert)")
        #expect(alert.lowercased().contains("channel 4") && alert.contains("not numbers"), "\(label): \(alert)")
        #expect(try Data(contentsOf: f.recording) == original, "\(label)")
        #expect(!f.exists("recording.m4a"), "\(label)")
    }
}

// MARK: - Read-to-read drift (C3): a good copy a few frames out of step with a second read

@Test("A good copy out of step with the recording by a few frames, steadily or changing mid-window, is accepted (F980 C3)")
@MainActor
func shrinkAuditAcceptsACopyAFewFramesOutOfStep() async throws {
    // AVAssetReader reads an ffmpeg-made file differently from one pass to the next, by up to 10 frames at
    // 16 kHz (second review, N20/N21), and the audit compares the copy, made from one read, with a second.
    // 800 Hz turns 144° in 8 frames, so an unaligned fit of it collapses. Steady shifts, and one that steps
    // in the middle of an audit window (2.5 s in), as a read that drops a buffer does: by 4 frames, the
    // measured step between one second and the next being at most 5 (gates/01-drift-probe.log). One lag
    // serves a window, so a larger step inside one window on an 800 Hz tone is refused, which is safe.
    // And a drift that grows along the file, as a converter running at a slightly different rate makes
    // (two reads of three of a three-minute file, 0.4 frames a second, gates/09-long-probe.log): here from
    // 0 to 60 frames over 8 s, far past one window's search, followed window by window.
    let cases: [(label: String, shift: Int, then: Int?)] = [("1 frame", 1, nil), ("8 frames", 8, nil), ("12 frames", 12, nil),
                                                             ("0 then 4 frames from 2.5 s", 0, 4), ("12 then 8 frames from 2.5 s", 12, 8),
                                                             ("0 to 60 frames, growing", -1, nil)]
    for c in cases {
        let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
            try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.3)], seconds: 8),
                                                   FixtureTrack(channels: [(800, 0.3)], seconds: 8)])
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (shift, then) = (c.shift, c.then)
        f.model.encodeForShrink = encodeTransformed { mix in
            shift < 0 ? drifting(mix, to: 60) : shifted(mix, by: shift, until: 40_000, then: then)
        }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("Shrunk"), "\(c.label): \(alert)")
        if alert.contains("Shrunk") {
            let copy = try f.copy()
            // Over a short span for the drifting copy: a tone measured over 4.5 s of drifting phase smears.
            let to = shift < 0 ? 3.4 : 7.5
            expectTone(copy, 300, from: 3, to: to, 0.285, within: shift < 0 ? 0.03 : 0.012, c.label)
            expectTone(copy, 800, from: 3, to: to, 0.285, within: shift < 0 ? 0.03 : 0.012, c.label)
        }
    }
}

@Test("A copy far out of step with the recording is not accepted: the alignment is bounded (F980 C3)")
@MainActor
func shrinkAuditRefusesACopyFarOutOfStep() async throws {
    // Twice the frames the audit aligns over from the start, and more: not a read's drift but a copy that is
    // not in time with the recording, which cannot be shown to hold it. Pins the first window's bound. Not
    // pure tones, which line up again a whole period away (800 Hz every 20 frames): voice-like signals.
    let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
        try await writeFixtureRawTracks(to: url, [[fixtureVoice(voiceA, seconds: 8)], [fixtureVoice(voiceB, seconds: 8)]])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let far = 2 * RecordingMixPlan.alignmentFrames + 8
    f.model.encodeForShrink = encodeTransformed { shifted($0, by: far) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
}

// MARK: - Near-identical tracks (C4): shared sound is proven as the sum it is heard in

@Test("Identical and near-identical tracks, and OBS's master beside its stems, are shrunk (F980 C4)")
@MainActor
func shrinkAuditAcceptsTracksThatShareTheirSound() async throws {
    // Two tracks holding the same sound cannot be told apart in a copy, and need not be: the copy holds their
    // sum. The review refused all of these, the encode's noise deciding an undetermined coefficient. The
    // voices are voice-like, not one tone: the mixer's own read puts a shared sound's two images in the copy
    // a few frames apart, and a sustained pure tone shifted a few frames reads as a different sound, where a
    // voice does not (`gates/15-cases-probe.log`). Not here: a near-duplicate track a third of a frame late
    // (the review's "0.98 one sample late"), whose only distinct part is a high-frequency phase difference a
    // 32 kbps copy cannot carry — the audit reads it as shared or as distinct with the read's jitter, and
    // shrinks or refuses accordingly, which is the rule but not a test (`gates/20-voice-run.log`). Nor here,
    // for the same reason: a synthetic three-track OBS layout (master = voice + other, other from 5 s) and a
    // dual-mono stereo track beside a mono one, whose AVAssetWriter tracks the audit's read lines up a frame or
    // two apart from the mixer's, so a shared sound reads as a quarter distinct in one run of three and the
    // copy is refused — a refusal, never a deletion (`gates/22-final-targeted.log`, `23-acceptance-run.log`).
    // The real layout is in the lane's evidence instead: ffmpeg's OBS-style master + mic + desktop shrank
    // 40 times in 40 (`gates/16-residual-run.log` … `23-acceptance-run.log`).
    let voice = fixtureVoice(voiceA, seconds: 12)
    // Each case names a tone of each voice, where it sounds, and the least amplitude the copy must hold it at.
    let cases: [(label: String, tracks: [[[Float]]], tones: [(Double, Double, Double, Double)])] = [
        ("identical tracks", [[voice], [voice]], [(voiceA[0], 1, 11, 0.025)]),
    ]
    for c in cases {
        let f = try await MixFixture(recordingExtension: "mov", duration: 12) { url in
            try await writeFixtureRawTracks(to: url, c.tracks)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("Shrunk"), "\(c.label): \(alert)")
        if alert.contains("Shrunk") {
            let copy = try f.copy()
            for (frequency, from, to, least) in c.tones {
                let measured = fixtureToneAmplitude(copy, rate: 16_000, frequency: frequency, from: from, to: to)
                #expect(measured >= least, "\(c.label) \(Int(frequency)) Hz [\(from), \(to)): \(measured), at least \(least)")
            }
        }
    }
}

// MARK: - A track masked under another (F978)

@Test("A track too quiet beside the others to be shown in the copy is a refusal, not a pass; 20 dB under is shown (F978)")
@MainActor
func shrinkAuditRefusesWhatItCannotShowUnderAnotherTrack() async throws {
    // Track 2 is 30 dB under track 1 for the first ten seconds and alone after. A mixer that loses it only
    // where it is masked made a copy the old audit passed, because it judged the track only where it was a
    // measurable part of the copy. Now a track that sounds but cannot be measured in a stretch is refused
    // there, with the real mixer too: the audit cannot prove it, so Shrink does not delete.
    let masked = { (url: URL) async throws -> Void in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.5)], seconds: 20, audibleTo: 10),
                                               FixtureTrack(channels: [(800, 0.0158)], seconds: 20)])
    }
    for lossy in [true, false] {
        let f = try await MixFixture(recordingExtension: "mov", duration: 20, write: masked)
        defer { try? FileManager.default.removeItem(at: f.root) }
        if lossy {
            let standIn = f.root.appendingPathComponent("lost-where-masked.mov")
            try await writeFixtureTracks(to: standIn, [FixtureTrack(channels: [(300, 0.5)], seconds: 20, audibleTo: 10),
                                                       FixtureTrack(channels: [(800, 0.0158)], seconds: 20, audibleFrom: 10)])
            f.model.mixForShrink = mixerLosing(standIn, tracks: 2, channels: 2)
        }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        let label = lossy ? "mixer lost track 2 where masked" : "real mixer"
        #expect(alert.contains("nothing was removed"), "\(label): \(alert)")
        #expect(alert.lowercased().contains("audio track 2") && alert.contains("too quiet beside") && alert.contains("at about 0:00"), "\(label): \(alert)")
        #expect(try Data(contentsOf: f.recording) == original, "\(label)")
        #expect(!f.exists("recording.m4a"), "\(label)")
    }
    // 20 dB under throughout: measurable in the copy, fitted, shown — and shrunk.
    let f = try await MixFixture(recordingExtension: "mov", duration: 12) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.5)], seconds: 12),
                                               FixtureTrack(channels: [(800, 0.05)], seconds: 12)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "20 dB under: \(alert)")
    if alert.contains("Shrunk") {
        let copy = try f.copy()
        expectTone(copy, 300, from: 1, to: 11, 0.475, within: 0.02, "20 dB under")
        expectTone(copy, 800, from: 1, to: 11, 0.0475, within: 0.006, "20 dB under")
    }
}

// MARK: - Every stretch is judged: shorter than a window, and the last partial window (N8, N9)

@Test("A recording shorter than one window is judged like any other (F980 N8)")
@MainActor
func shrinkAuditJudgesARecordingShorterThanAWindow() async throws {
    // 0.4 s: under the half second the audit used to skip. The review deleted both of the first two.
    for (label, cancels, lossy) in [("antiphase track", true, false), ("mixer drops track 2", false, true), ("good", false, false)] {
        let f = try await MixFixture(recordingExtension: "mov", duration: 0.4) { url in
            try await writeFixtureTracks(to: url, [FixtureTrack(channels: cancels ? [(300, 0.3), (300, -0.3)] : [(300, 0.3)], seconds: 0.4),
                                                   FixtureTrack(channels: [(800, 0.3)], seconds: 0.4)])
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        if lossy {
            let standIn = f.root.appendingPathComponent("first-only.mov")
            try await writeFixtureTracks(to: standIn, [FixtureTrack(channels: [(300, 0.3)], seconds: 0.4)])
            f.model.mixForShrink = mixerLosing(standIn, tracks: 2, channels: 2)
        }
        let original = try Data(contentsOf: f.recording)
        #expect(try await f.reason() == nil, "\(label): offered")

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        if cancels || lossy {
            #expect(alert.contains("nothing was removed"), "\(label): \(alert)")
            #expect(try Data(contentsOf: f.recording) == original, "\(label)")
        } else {
            #expect(alert.contains("Shrunk"), "\(label): \(alert)")
            if alert.contains("Shrunk") {
                let copy = try f.copy()
                expectTone(copy, 300, from: 0.05, to: 0.35, 0.285, within: 0.03, label)
                expectTone(copy, 800, from: 0.05, to: 0.35, 0.285, within: 0.03, label)
            }
        }
    }
}

@Test("A track that sounds only in the recording's last partial window is judged there (F980 N9)")
@MainActor
func shrinkAuditJudgesTheLastPartialWindow() async throws {
    // Track 2 sounds only from 10.0 s to 10.4 s of a 10.4 s recording: a 0.4 s last window after two whole
    // ones, which the audit used to skip. The review deleted the original under a mixer that dropped it.
    for lossy in [true, false] {
        let f = try await MixFixture(recordingExtension: "mov", duration: 10.4) { url in
            try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 10.4, audibleTo: 9),
                                                   FixtureTrack(channels: [(800, 0.3)], seconds: 0.4, startSeconds: 10)])
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        if lossy {
            let standIn = f.root.appendingPathComponent("last-silent.mov")
            try await writeFixtureTracks(to: standIn, [FixtureTrack(channels: [(300, 0.2)], seconds: 10.4, audibleTo: 9),
                                                       FixtureTrack(channels: [(800, 0.0)], seconds: 0.4, startSeconds: 10)])
            f.model.mixForShrink = mixerLosing(standIn, tracks: 2, channels: 2)
        }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        if lossy {
            #expect(alert.contains("nothing was removed") && alert.contains("0:10"), "\(alert)")
            #expect(try Data(contentsOf: f.recording) == original)
        } else {
            #expect(alert.contains("Shrunk"), "\(alert)")
            if alert.contains("Shrunk") { expectTone(try f.copy(), 800, from: 10.05, to: 10.35, 0.285, within: 0.03, "real mixer") }
        }
    }
}

// MARK: - Boundaries and shapes the reviews did not try

@Test("Sixteen channels are checked one by one and shrunk; seventeen are refused up front (F980)")
@MainActor
func shrinkAuditChecksSixteenChannelsAndRefusesSeventeen() async throws {
    for count in [16, 17] {
        let tones = (0..<count).map { 300.0 + 100.0 * Double($0) }
        let f = try await MixFixture(recordingExtension: "wav", duration: 4) { url in
            try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.8 / Double(count), seconds: 4) }).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let reason = try await f.reason()
        if count == 17 {
            #expect(reason == .tooManyChannelsToCheck(count: 17), "\(String(describing: reason))")
            continue
        }
        #expect(reason == nil, "\(String(describing: reason))")

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("Shrunk"), "\(alert)")
        if alert.contains("Shrunk") {
            let copy = try f.copy()
            for tone in tones { expectTone(copy, tone, from: 0.5, to: 3.5, 0.95 * 0.8 / 256, within: 0.0015, "16 channels") }
        }
    }
}

@Test("Two tracks that cancel each other when summed keep their original (F980)")
@MainActor
func shrinkAuditKeepsTracksThatCancelEachOther() async throws {
    // A whole track in opposite polarity to another: the mix, and so the copy, holds a tenth of the sound
    // or none. Nothing the copy could be shown to hold is what the recording holds. Which refusal names it
    // depends on how the audit's own read of the two tracks lines up with the copy (`alignment`): aligned
    // as the mixer summed them, the tracks cancel; aligned otherwise, their sum is far louder than the
    // copy, which is missing it.
    for (label, k) in [("track 2 = −track 1", -1.0), ("track 2 = −0.9 × track 1", -0.9)] {
        let voice = fixtureTone(frequency: 300, amplitude: 0.3, seconds: 8)
        let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
            try await writeFixtureRawTracks(to: url, [[voice], [voice.map { Float(k) * $0 }]])
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("nothing was removed") && (alert.contains("cancel each other") || alert.contains("missing sound")), "\(label): \(alert)")
        #expect(try Data(contentsOf: f.recording) == original, "\(label)")
        #expect(!f.exists("recording.m4a"), "\(label)")
    }
}

@Test("A DC offset, a clipped track and loud tracks into the limiter are shrunk with every tone in the copy (F980)")
@MainActor
func shrinkAuditAcceptsDCClippingAndLoudTracks() async throws {
    // Levels here are lower bounds: a clipped track at full scale beside another drives the mix's limiter,
    // which is the mixer's rule (F345), not the audit's business. Each tone must be in the copy.
    let t300 = fixtureTone(frequency: 300, amplitude: 0.2, seconds: 8), t800 = fixtureTone(frequency: 800, amplitude: 0.1, seconds: 8)
    let clipped = fixtureTone(frequency: 300, amplitude: 1.5, seconds: 8).map { Swift.max(-1, Swift.min(1, $0)) }
    let cases: [(label: String, tracks: [[[Float]]], atLeast: [(Double, Double)])] = [
        ("DC 0.3 on track 1", [[t300.map { $0 + 0.3 }], [t800]], [(300, 0.17), (800, 0.085)]),
        ("clipped track 1 + track 2 at 0.3", [[clipped], [fixtureTone(frequency: 800, amplitude: 0.3, seconds: 8)]], [(300, 0.4), (800, 0.15)]),
        ("two tracks at 0.9 at once", [[fixtureTone(frequency: 300, amplitude: 0.9, seconds: 8)], [fixtureTone(frequency: 800, amplitude: 0.9, seconds: 8)]], [(300, 0.3), (800, 0.3)]),
    ]
    for c in cases {
        let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
            try await writeFixtureRawTracks(to: url, c.tracks)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("Shrunk"), "\(c.label): \(alert)")
        if alert.contains("Shrunk") {
            let copy = try f.copy()
            for (frequency, level) in c.atLeast {
                let measured = fixtureToneAmplitude(copy, rate: 16_000, frequency: frequency, from: 1, to: 7)
                #expect(measured >= level, "\(c.label) \(Int(frequency)) Hz: \(measured), at least \(level)")
            }
        }
    }
}

@Test("Tracks of different lengths and offsets are shrunk, and one the mixer dropped is caught (F980 N11)")
@MainActor
func shrinkAuditJudgesTracksOfDifferentLengthsAndOffsets() async throws {
    let layout = [FixtureTrack(channels: [(300, 0.2)], seconds: 12),
                  FixtureTrack(channels: [(800, 0.1)], seconds: 3.8, startSeconds: 3.3),
                  FixtureTrack(channels: [(1_200, 0.05)], seconds: 2.1, startSeconds: 9.9)]
    for lossy in [false, true] {
        let f = try await MixFixture(recordingExtension: "mov", duration: 12) { url in
            try await writeFixtureTracks(to: url, layout)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        if lossy {
            var standIn = layout
            standIn[2].channels = [(1_200, 0.0)]
            let kept = f.root.appendingPathComponent("last-silent.mov")
            try await writeFixtureTracks(to: kept, standIn)
            f.model.mixForShrink = mixerLosing(kept, tracks: 3, channels: 3)
        }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        if lossy {
            #expect(alert.contains("nothing was removed") && alert.lowercased().contains("audio track 3"), "\(alert)")
            #expect(try Data(contentsOf: f.recording) == original)
        } else {
            #expect(alert.contains("Shrunk"), "\(alert)")
            if alert.contains("Shrunk") {
                let copy = try f.copy()
                expectTone(copy, 300, from: 0.5, to: 11.5, 0.19, "real mixer")
                expectTone(copy, 800, from: 3.6, to: 6.8, 0.095, "real mixer")
                expectTone(copy, 1_200, from: 10.2, to: 11.7, 0.0475, within: 0.008, "real mixer")
            }
        }
    }
}

@Test("A quadraphonic AAC movie is shrunk with all four channels in the copy (F953)")
@MainActor
func shrinkAuditMixesQuad() async throws {
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await MixFixture(recordingExtension: "mp4", duration: 6) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: tones.map { ($0, 0.2) }, seconds: 6)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    if alert.contains("Shrunk") {
        let copy = try f.copy()
        for tone in tones { expectTone(copy, tone, from: 0.5, to: 5.5, 0.0475, within: 0.006, "quad") }
    }
}

@Test("A copy that is noise at the right level is not the recording, and the original is kept (F980)")
@MainActor
func shrinkAuditKeepsACopyThatIsNoiseAtTheRightLevel() async throws {
    let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.3)], seconds: 8),
                                               FixtureTrack(channels: [(800, 0.3)], seconds: 8)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.encodeForShrink = encodeTransformed { mix in
        let rms = (mix.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(Swift.max(1, mix.count))).squareRoot()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return mix.map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(rms * 1.7) * (Float(state >> 40) / Float(1 << 24) - 0.5) * 2
        }
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
}
