import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1001, round 2 — the user's rule (2026-10-15): "Refuse any with cancellation". Both reviews of the first round
// deleted originals whose channels cancel: a side voice 1–6 dB under the middle one, equal-level speech talking
// over each other, a side voice alone for about a second, a cancellation confined to part of the spectrum, a quiet
// cancelling stretch after a loud one (F2-3), a WAV marked centre + LFE, and a link import's stereo download beside
// its mono WAV (F2-1). Every one of them, rebuilt here from synthetic voices (CI-safe; the speech ones need the
// bench clips and are gated), must keep its original; and ordinary stereo must still shrink. Driven through the
// calls the Shrink button makes, with the real encoder and decoder.

private let rate = 16_000
/// How long the voices run: six seconds since the macos-15 suite reached its watchdog (CI fix after run
/// 38859340988), the measure's cost being in proportion. Three probes keep twelve (`shrinkKeepsEveryCancellation…`):
/// two of them pin the stretch rule only while their cancelling stretch is a small share of a five-second
/// window, which the first round's link then misses — shortened, to eight and six seconds, that link caught them
/// too, and removing the stretch rule no longer failed them (measured). Each probe's verdict under each of the rule's
/// mutants is otherwise the same at these lengths as at twelve seconds.
private let voiceSeconds: Double = 6

/// A voice-like sound at 16 kHz: twelve tones, each swelling at its own rate.
private func voice16(_ tones: [Double], amplitude: Double = 0.03, seconds: Double = voiceSeconds, detune: Double = 0) -> [Float] {
    let count = Int(seconds * Double(rate))
    var out = [Float](repeating: 0, count: count)
    for (index, tone) in tones.enumerated() {
        let swell = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        let step = 2 * Double.pi * (tone + detune) / Double(rate), swellStep = 2 * Double.pi * swell / Double(rate)
        for n in 0..<count {
            out[n] += Float(amplitude * sin(step * Double(n)) * (0.55 + 0.45 * sin(swellStep * Double(n) + phase)))
        }
    }
    return out
}

private let toneA: [Double] = [311, 457, 619, 737, 911, 1_171, 1_409, 1_777, 2_389, 2_917, 3_571, 4_283]
private let toneB: [Double] = [353, 419, 541, 823, 953, 1_291, 1_613, 2_011, 2_557, 2_963, 3_803, 4_621]
private let a16 = voice16(toneA)
private let b16 = voice16(toneB)
private let bLow16 = voice16(toneB.filter { $0 < 1_000 })
private let bHigh16 = voice16(toneB.filter { $0 >= 1_000 })
private let bAbove2k16 = voice16(toneB.filter { $0 >= 2_000 })
private let bBelow2k16 = voice16(toneB.filter { $0 < 2_000 })

private func mix(_ a: [Float], _ b: [Float], _ k: Float = 1) -> [Float] {
    let count = Swift.min(a.count, b.count)
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count { out[n] = a[n] + k * b[n] }
    return out
}
private func scaled(_ a: [Float], _ k: Float) -> [Float] { a.map { $0 * k } }
/// `x` where `t` is inside one of `on` (seconds), silence elsewhere.
private func gated(_ x: [Float], _ on: [(Double, Double)]) -> [Float] {
    var out = [Float](repeating: 0, count: x.count)
    for (from, to) in on {
        for n in Swift.max(0, Int(from * Double(rate)))..<Swift.min(x.count, Int(to * Double(rate))) { out[n] = x[n] }
    }
    return out
}
private func late(_ x: [Float], _ frames: Int) -> [Float] {
    let head = [Float](repeating: 0, count: frames)
    let body: [Float] = Array(x.dropLast(frames))
    return head + body
}
private func midSide(_ a: [Float], _ b: [Float]) -> [[Float]] { [mix(a, b), mix(a, b, -1)] }

/// Seeded white noise, uniform in ±`amplitude`, as long as the voices.
private func noise16(seed: UInt64, amplitude: Float) -> [Float] {
    var state = seed
    return (0..<a16.count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000 * amplitude
    }
}

/// A 16-bit PCM WAV at `rate`, `WAVE_FORMAT_EXTENSIBLE` with `mask` when one is given.
private func pcm16(_ channels: [[Float]], rate: Int = rate, mask: UInt32? = nil) -> Data {
    let count = channels.count, frames = channels.map(\.count).min() ?? 0
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(frames * count * 2)
    let format: UInt32 = mask == nil ? 16 : 40
    data.append(contentsOf: Array("RIFF".utf8)); u32(4 + 8 + format + 8 + bytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(format)
    u16(mask == nil ? 1 : 0xFFFE); u16(UInt16(count)); u32(UInt32(rate)); u32(UInt32(rate * count * 2))
    u16(UInt16(count * 2)); u16(16)
    if let mask {
        u16(22); u16(16); u32(mask)
        let pcm: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        data.append(contentsOf: pcm)
    }
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    var samples = [Int16](repeating: 0, count: frames * count)
    for frame in 0..<frames {
        for channel in 0..<count {
            let value = channels[channel][frame].isFinite ? Swift.max(-1, Swift.min(1, channels[channel][frame])) : 0
            samples[frame * count + channel] = Int16((value * 32_767).rounded())
        }
    }
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// Shrinks a two-channel WAV holding `channels` and returns whether the original was kept unchanged, and the alert.
@MainActor
private func shrinkWAV(_ channels: [[Float]], rate: Int = rate, mask: UInt32? = nil) async throws -> (kept: Bool, alert: String) {
    let seconds = Double(channels.map(\.count).min() ?? 0) / Double(rate)
    let f = try await MixFixture(recordingExtension: "wav", duration: seconds) { url in
        try pcm16(channels, rate: rate, mask: mask).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)
    await f.shrink()
    let alert = f.model.alertMessage ?? "nil"
    let kept = (try? Data(contentsOf: f.recording)) == original && !f.exists("recording.m4a")
    return (kept, alert)
}

/// `shrinkWAV`, and what this host makes of the file. Removed: `copy` is the copy Shrink kept, decoded. Kept: whether
/// the readers Shrink uses — `decodeForShrink`, and `channelPresenceForShrink` against a copy from `encodeForShrink`,
/// the model's own — can read the file here; `unreadable` names the first that cannot, and why, or is nil.
@MainActor
private func shrinkWAVAskingTheHost(_ channels: [[Float]], mask: UInt32) async throws
    -> (kept: Bool, alert: String, unreadable: String?, copy: [Float]?) {
    let seconds = Double(channels.map(\.count).min() ?? 0) / Double(rate)
    let f = try await MixFixture(recordingExtension: "wav", duration: seconds) { url in
        try pcm16(channels, mask: mask).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)
    await f.shrink()
    let alert = f.model.alertMessage ?? "nil"
    guard (try? Data(contentsOf: f.recording)) == original, !f.exists("recording.m4a") else {
        let copy = try? fixtureDecode(f.folder.appendingPathComponent("recording.m4a")).channels.first
        return (false, alert, nil, copy ?? [])
    }
    let copy = f.root.appendingPathComponent("host.m4a")
    do { _ = try await f.model.decodeForShrink(f.recording) } catch { return (true, alert, "decodeForShrink: \(error)", nil) }
    do { try f.model.encodeForShrink(f.recording, copy, f.root.appendingPathComponent("host.wav")) } catch {
        return (true, alert, "encodeForShrink: \(error)", nil)
    }
    do { _ = try await f.model.channelPresenceForShrink(f.recording, copy) } catch {
        return (true, alert, "channelPresenceForShrink: \(error)", nil)
    }
    return (true, alert, nil, nil)
}

// MARK: - Every review probe keeps its original (CI-safe, synthetic)

@Test("Every channel cancellation the reviews of F1001 made deletes nothing now (F1001 round 2)")
@MainActor
func shrinkKeepsEveryCancellationTheReviewsMade() async throws {
    // Twelve seconds for the probes whose cancelling stretch must be a small share of the windows past 0:05.
    let a12 = voice16(toneA, seconds: 12), b12 = voice16(toneB, seconds: 12)
    // F2-3: a loud chord, the same on both channels, then mid/side 22 dB quieter.
    var loudThenQuiet = midSide(scaled(a12, 0.08), scaled(b12, 0.08))
    let chord = voice16([196, 294, 392, 587, 784, 1_175], amplitude: 0.12, seconds: 4)
    for n in chord.indices { loudThenQuiet[0][n] = chord[n]; loudThenQuiet[1][n] = chord[n] }
    let probes: [(String, [[Float]])] = [
        ("side voice 3 dB down throughout (review 2's near-bound pin)", midSide(a16, scaled(b16, 0.708))),
        ("side voice 6 dB down throughout (review 1's miss)", midSide(a16, scaled(b16, 0.5))),
        ("side voice alone for 1.0 s", midSide(gated(a16, [(0, 2), (3, voiceSeconds)]), gated(b16, [(2, 3)]))),
        ("side voice alone for 0.6 s", midSide(gated(a16, [(0, 2), (2.6, voiceSeconds)]), gated(b16, [(2, 2.6)]))),
        ("side voice alone for 2.4 s across 0:05", midSide(gated(a12, [(0, 3.8), (6.2, 12)]), gated(b12, [(3.8, 6.2)]))),
        ("side voice for 2 s over the middle one", midSide(a12, gated(b12, [(4, 6)]))),
        ("side voice cancelling only from 2 kHz", [mix(mix(a16, bBelow2k16), bAbove2k16), mix(mix(a16, bBelow2k16), bAbove2k16, -1)]),
        ("side voice cancelling only below 1 kHz", [mix(mix(a16, bHigh16), bLow16), mix(mix(a16, bHigh16), bLow16, -1)]),
        ("side voice inverted and 0.25 ms late", [mix(a16, b16), mix(a16, late(b16, 4), -1)]),
        ("L = A + B, R = A − 0.8 B", [mix(a16, b16), mix(a16, b16, -0.8)]),
        ("S2 with B only in [4, 6)", [gated(b16, [(4, 6)]), mix(a16, gated(b16, [(4, 6)]), -1)]),
        ("a loud stretch, then a quiet cancelling one (F2-3)", loudThenQuiet),
    ]
    var deleted: [String] = []
    for (label, channels) in probes {
        let outcome = try await shrinkWAV(channels)
        if !outcome.kept || !outcome.alert.contains("nothing was removed") { deleted.append("\(label): \(outcome.alert)") }
        #expect(outcome.alert.contains("cancel each other"), "\(label): \(outcome.alert)")
    }
    #expect(deleted.isEmpty, "\(deleted)")
}

@Test("What F1001's first round kept, its second round's spaced-microphone allowance does not delete (F1001 round 4)")
@MainActor
func shrinkKeepsWhatTheFirstRoundKept() async throws {
    // Review 1 of round 2: the 3 ms alignment search reads an inverted steady tone as a delayed one — an inverted
    // tone and one half a period late are the same signal — so a loud cancelling tone read 0.000; a side voice under
    // a talker on microphones 3 ms apart read 0.075; and a 0.1 s file has no stretch of three frames' spread. Round 1
    // (48ef1c4) kept all three. Each cancels exactly in the mix.
    let tone = voice16([953], amplitude: 0.1)
    var buzz = [Float](repeating: 0, count: a16.count)
    for (index, harmonic) in stride(from: 1, through: 31, by: 2).map({ Double($0) * 200 }).enumerated() where harmonic < 7_800 {
        let step = 2 * Double.pi * harmonic / Double(rate), amplitude = 0.06 / Double(2 * index + 1)
        for n in buzz.indices { buzz[n] += Float(amplitude * sin(step * Double(n))) }
    }
    let side = scaled(b16, 0.708)
    let probes: [(String, [[Float]])] = [
        ("a 953 Hz tone inverted under voice A, at its level", midSide(a16, tone)),
        ("a 200 Hz odd-harmonic buzz inverted under voice A", midSide(a16, buzz)),
        ("voice A on microphones 3 ms apart, voice B inverted 3 dB down", [mix(a16, side), mix(late(a16, 48), side, -1)]),
        ("a whole file of 0.1 s, mid/side", midSide(Array(a16.prefix(1_600)), Array(b16.prefix(1_600)))),
    ]
    var deleted: [String] = []
    for (label, channels) in probes {
        let outcome = try await shrinkWAV(channels)
        if !outcome.kept { deleted.append("\(label): \(outcome.alert)") }
    }
    #expect(deleted.isEmpty, "\(deleted)")
}

@Test("A side voice only partly coherent across the channels is still caught; only the coherence gate lets through what beats (F1001 round 4)")
@MainActor
func shrinkKeepsAPartlyDecorrelatedCancellation() async throws {
    // Review 1 of round 2: no app-level test failed with the coherence gate removed or raised to 0.95. These do,
    // measured (gates/r4-08-mutant-*.txt): the side voice on the right is a fifth a 2 Hz-detuned copy, so its bins
    // are coherent between the gate and 0.95, and the first round's link reads it at 0.18 and 0.14, under its own
    // bound, so the stretch rule alone catches it.
    let decorrelated = mix(scaled(b16, 0.894), scaled(voice16(toneB, detune: 2), 0.447))
    let probes: [(String, [[Float]])] = [
        ("side voice 6 dB down, a fifth decorrelated", [mix(a16, scaled(b16, 0.5)), mix(a16, scaled(decorrelated, 0.5), -1)]),
        ("side voice alone for 1 s, a fifth decorrelated",
         [mix(gated(a16, [(0, 2), (3, voiceSeconds)]), gated(b16, [(2, 3)])), mix(gated(a16, [(0, 2), (3, voiceSeconds)]), gated(decorrelated, [(2, 3)]), -1)]),
    ]
    for (label, channels) in probes {
        let outcome = try await shrinkWAV(channels)
        #expect(outcome.kept && outcome.alert.contains("cancel each other"), "\(label): \(outcome.alert)")
    }
}

@Test("A WAV whose mask puts a channel where the compression leaves it out is kept; masks it mixes evenly shrink wherever this host can read them (F1001 round 3, R2-C)")
@MainActor
func shrinkJudgesAWAVByWhatTheCompressionKeepsOfItsMask() async throws {
    // Review 1 of round 2: afconvert's mix follows the mask and drops an LFE channel, here a voice 12 dB down.
    // Review 2, R2-C: masks it mixes evenly — none, back, side, the centre pair, a centre beside a front — were
    // refused too, though nothing is lost. Measured, `gates/r3-01-layouts.txt`, `r3-04-pairs.txt`.
    let quietB = scaled(b16, 0.25)
    for (name, mask) in [("centre and LFE", UInt32(0x4 | 0x8)), ("left and LFE", UInt32(0x1 | 0x8))] {
        let outcome = try await shrinkWAV([a16, quietB], mask: mask)
        #expect(outcome.kept, "\(name): \(outcome.alert)")
        #expect(outcome.alert.contains("which the compression leaves out of a mono copy"), "\(name): \(outcome.alert)")
    }
    // The masks it mixes evenly, judged by what this host's readers can do. On macos-15 (run 38859340988) the
    // side pair, the centre pair and a front left beside a centre were kept, "could not be read to check": fail-
    // closed, so nothing was lost; macOS 27 reads all six. So on every host nothing may be removed unless
    // the copy holds both voices; and a file is expected to shrink only where the readers Shrink itself uses can
    // read it here (`shrinkWAVAskingTheHost`) — and where they cannot, kept for exactly that reason.
    let unreadable = AppModel.ShrinkFailure.unreadableOriginal.errorDescription ?? "?"
    let ownA = fixtureToneAmplitude(a16, rate: Double(rate), frequency: toneA[0]), ownB = fixtureToneAmplitude(quietB, rate: Double(rate), frequency: toneB[0])
    for (name, mask) in [("front left and right", UInt32(0x3)), ("no positions", UInt32(0)), ("back left and right", UInt32(0x30)),
                         ("side left and right", UInt32(0x600)), ("the centre pair", UInt32(0xC0)), ("front left and centre", UInt32(0x5))] {
        let outcome = try await shrinkWAVAskingTheHost([a16, quietB], mask: mask)
        if let copy = outcome.copy {
            // Removed: only as Shrunk, and only with both voices in the copy — an even mix holds each at about half.
            let heldA = fixtureToneAmplitude(copy, rate: Double(rate), frequency: toneA[0])
            let heldB = fixtureToneAmplitude(copy, rate: Double(rate), frequency: toneB[0])
            #expect(outcome.alert.contains("Shrunk"), "\(name): removed, but \(outcome.alert)")
            #expect(heldA > ownA / 4 && heldB > ownB / 4,
                    "\(name): removed, but the copy holds A \(heldA) of \(ownA) and B \(heldB) of \(ownB)")
        } else if let reader = outcome.unreadable {
            print("F1001 host: \(name) kept, as this host's \(reader)")
            #expect(outcome.alert.contains(unreadable), "\(name): \(reader), but \(outcome.alert)")
        } else {
            Issue.record("\(name): kept though this host's readers read it: \(outcome.alert)")
        }
    }
}

/// 1.5 s of steady sines at 0.1 each, at 16 kHz.
private func steadyTones(_ frequencies: [Double]) -> [Float] {
    var out = [Float](repeating: 0, count: 24_000)
    for frequency in frequencies {
        let step = 2 * Double.pi * frequency / 16_000
        for n in out.indices { out[n] += Float(0.1 * sin(step * Double(n))) }
    }
    return out
}

/// What afconvert's encode keeps of each channel of a two-channel file: the copy's level of voice A (channel 1)
/// and B (channel 2), each 0.05 when mixed evenly.
private func keptByTheEncode(_ url: URL, scratch: URL) throws -> (a: Double, b: Double) {
    let out = scratch.appendingPathComponent("\(UUID().uuidString).m4a")
    try AudioCompressor.compressSpeech(input: url, output: out, workingWAV: scratch.appendingPathComponent("w-\(UUID().uuidString).wav"))
    let copy = try #require(try fixtureDecode(out).channels.first)
    return (fixtureToneAmplitude(copy, rate: 16_000, frequency: 311, from: 0.3, to: 1.2),
            fixtureToneAmplitude(copy, rate: 16_000, frequency: 353, from: 0.3, to: 1.2))
}

@Test("Every channel layout the rule lets through keeps both channels in the real encode, and the ones it stops are the measured ones (F1001 round 3)")
func channelLayoutRuleMatchesTheEncode() throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("F1001-layouts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Steady tones, so a level read off the copy is the channel's own.
    let steadyA = steadyTones([311, 619, 911]), steadyB = steadyTones([353, 541, 953])
    typealias Positions = MeetingStoragePlan.ChannelPositions
    var files: [(String, URL, Positions)] = []
    for (mask, expected) in [(UInt32?.none, Positions.keepsBoth), (0, .keepsBoth), (0x3, .keepsBoth), (0x5, .keepsBoth), (0x6, .keepsBoth),
                             (0x30, .keepsBoth), (0xC0, .keepsBoth), (0x600, .keepsBoth), (0x104, .keepsBoth), (0x1800, .keepsBoth),
                             (0x7, .keepsBoth), (0x9, .leavesOneOut), (0xA, .leavesOneOut), (0xC, .leavesOneOut), (0x108, .leavesOneOut),
                             (0x3_0000, .leavesOneOut)] as [(UInt32?, Positions)] {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        try pcm16([steadyA, steadyB], mask: mask).write(to: url)
        files.append(("WAV mask \(mask.map { String($0, radix: 16) } ?? "plain")", url, expected))
    }
    for (name, tag, expected) in [("Stereo", kAudioChannelLayoutTag_Stereo, Positions.keepsBoth),
                                  ("StereoHeadphones", kAudioChannelLayoutTag_StereoHeadphones, .keepsBoth),
                                  ("MatrixStereo", kAudioChannelLayoutTag_MatrixStereo, .keepsBoth),
                                  ("XY", kAudioChannelLayoutTag_XY, .keepsBoth), ("Binaural", kAudioChannelLayoutTag_Binaural, .keepsBoth),
                                  ("MidSide", kAudioChannelLayoutTag_MidSide, .leavesOneOut)] {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).caf")
        try writeLaidOut(url, [steadyA, steadyB], layout: channelLayout(tag: tag))
        files.append(("CAF tag \(name)", url, expected))
    }
    let keptLabels = MeetingStoragePlan.positionsMixedEvenly.sorted() + MeetingStoragePlan.centredPositions.sorted()
    for label in keptLabels {
        for partner: UInt32 in [1, 2] {
            let url = scratch.appendingPathComponent("\(UUID().uuidString).caf")
            try writeLaidOut(url, [steadyA, steadyB], layout: channelLayout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: [label, partner]))
            files.append(("CAF labels \(label),\(partner)", url, .keepsBoth))
        }
    }
    for label in MeetingStoragePlan.positionsLeftOut.sorted() {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).aif")
        try writeLaidOut(url, [steadyA, steadyB], layout: channelLayout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: [label, 1]))
        files.append(("AIFF labels \(label),1", url, .leavesOneOut))
    }
    var wrong: [String] = []
    for (name, url, expected) in files {
        let verdict = MeetingStoragePlan.monoMix(ofChannelLabels: DecodedAudio.channelLabels(of: url))
        if verdict != expected { wrong.append("\(name): the rule says \(verdict), expected \(expected)") }
        // What the rule lets through must keep both channels, at two-thirds of an even mix at least.
        if verdict == .keepsBoth {
            let kept = try keptByTheEncode(url, scratch: scratch)
            if kept.a < 0.033 || kept.b < 0.033 { wrong.append(String(format: "%@: let through, but the copy keeps A %.4f B %.4f", name, kept.a, kept.b)) }
        }
    }
    print("F1001 round 3 layouts: \(files.count) checked, \(wrong.count) wrong")
    #expect(wrong.isEmpty, "\(wrong)")
}

@Test("A link import's stereo download beside its mono WAV is not deleted when its channels cancel (F1001 round 2, F2-1)")
@MainActor
func shrinkKeepsADownloadWhoseChannelsCancelBesideItsMonoWAV() async throws {
    for ext in ["m4a", "caf"] {
        // The folder an interrupted link import leaves: the download, and ffmpeg's `-ac 1` WAV made from it.
        let downloadChannels = midSide(a16, b16)
        let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
            try pcm16([scaled(mix(downloadChannels[0], downloadChannels[1]), 0.5)]).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let download = f.folder.appendingPathComponent("recording.\(ext)")
        if ext == "caf" {
            let source = f.root.appendingPathComponent("download.wav")
            try pcm16(downloadChannels).write(to: source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "caff", "-d", "LEI16", source.path, download.path]
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        } else {
            let up: [[Float]] = downloadChannels.map { channel in
                var out = [Float](repeating: 0, count: channel.count * 3)
                for n in out.indices { out[n] = channel[n / 3] }
                return out
            }
            try await writeFixtureRawTracks(to: download, [up])
        }
        let before = try Data(contentsOf: download)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect((try? Data(contentsOf: download)) == before, ".\(ext): \(alert)")
        #expect(f.exists("recording.wav"), ".\(ext): \(alert)")
        #expect(alert.contains("also holds “recording.\(ext)”, which shrinking would delete"), ".\(ext): \(alert)")
    }
}

/// Writes `channels` (16 kHz) as a two-channel CAF or AIFF whose channel layout is `layout` — a raw
/// `AudioChannelLayout`, its descriptions included.
private func writeLaidOut(_ url: URL, _ channels: [[Float]], layout: [UInt8]) throws {
    var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    if url.pathExtension == "aif" { settings[AVLinearPCMIsBigEndianKey] = true }
    settings[AVChannelLayoutKey] = Data(layout)
    let avLayout = layout.withUnsafeBytes { AVAudioChannelLayout(layout: $0.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)) }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), interleaved: false, channelLayout: avLayout)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Swift.min(channels[0].count, channels[1].count)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<2 { for n in 0..<frames { data[channel][n] = channels[channel][n] } }
    try file.write(from: buffer)
}

/// A raw `AudioChannelLayout`: `tag`, with `bitmap` or the channel `labels` it names.
private func channelLayout(tag: AudioChannelLayoutTag, bitmap: UInt32 = 0, labels: [AudioChannelLabel] = []) -> [UInt8] {
    let header = MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size
    let total = header + Swift.max(1, labels.count) * MemoryLayout<AudioChannelDescription>.size
    var bytes = [UInt8](repeating: 0, count: total)
    bytes.withUnsafeMutableBytes { raw in
        let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = tag
        layout.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap)
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw.baseAddress! + header).assumingMemoryBound(to: AudioChannelDescription.self)
        for (index, label) in labels.enumerated() {
            descriptions[index] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
    }
    return bytes
}

@Test("A CAF or AIFF laid out centre + LFE, whose LFE channel the compression drops, is kept (F1001 round 3, R2-A)")
@MainActor
func shrinkKeepsACAFOrAIFFLaidOutCentreAndLFE() async throws {
    // Review 2 of round 2: voice B 16 dB down on the channel laid out as LFE was missing from the copy, under
    // the copy's own check (a twentieth of the mix), and the original deleted.
    let centreAndLFE = channelLayout(tag: kAudioChannelLayoutTag_UseChannelBitmap, bitmap: 0x4 | 0x8)
    for ext in ["caf", "aif"] {
        let f = try await MixFixture(recordingExtension: ext, duration: voiceSeconds) { url in
            try writeLaidOut(url, [a16, scaled(b16, 0.158)], layout: centreAndLFE)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.recording)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect((try? Data(contentsOf: f.recording)) == original, ".\(ext): \(alert)")
        #expect(!f.exists("recording.m4a"), ".\(ext): \(alert)")
        #expect(alert.contains("“recording.\(ext)”") && alert.contains("channels"), ".\(ext): \(alert)")
    }
}

// MARK: - The copy's own link, and an unreadable leftover (reviews' mutants M15, M18)

@Test("A copy that kept one channel of two voices is refused end to end, by the copy's check alone (F1001 round 2)")
@MainActor
func shrinkRefusesACopyThatKeptOneChannel() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try pcm16([a16, b16]).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    // An encode that keeps the left channel only — what afconvert does without `--mix` (F796). Its level
    // is within the band and every window keeps sound, so only the copy's link sees it.
    let scratch = f.root
    f.model.encodeForShrink = { _, output, work in
        let left = scratch.appendingPathComponent("left-\(UUID().uuidString).wav")
        try pcm16([a16]).write(to: left)
        try AudioCompressor.compressSpeech(input: left, output: output, workingWAV: work)
    }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav") && !f.exists("recording.m4a"), "\(alert)")
    #expect(alert.contains("The compressed copy is missing sound the recording has"), "\(alert)")
}

@Test("A resume keeps a two-channel leftover it cannot decode (F1001 round 2)")
@MainActor
func shrinkResumeKeepsALeftoverItCannotDecode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1001-r2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let leftover = folder.appendingPathComponent("recording.wav")
    try pcm16([a16, b16]).write(to: leftover)
    try AudioCompressor.compressSpeech(input: leftover, output: folder.appendingPathComponent("recording.m4a"),
                                       workingWAV: root.appendingPathComponent("work.wav"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(id: id, title: "Client call", duration: voiceSeconds,
                                     recordingPath: "Recordings/\(id.uuidString)/recording.m4a",
                                     status: .completed, transcriptText: "Hi."))
    model.availableBytesForShrink = { _ in .max }
    let real = model.decodeForShrink
    model.decodeForShrink = { url in
        if url.lastPathComponent == "recording.wav" { throw CocoaError(.fileReadCorruptFile) }
        return try await real(url)
    }

    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let alert = model.alertMessage ?? "nil"
    #expect(FileManager.default.fileExists(atPath: leftover.path), "\(alert)")
    #expect(alert.contains("“recording.wav”, which the compressed copy replaced, could not be checked against the copy, so it was kept."), "\(alert)")
}

// MARK: - Ordinary stereo still shrinks (controls, CI-safe)

@Test("Ordinary stereo still shrinks: rates, lengths, float, panned, DC, hiss, clipping, a phone's spacing (F1001 round 2)")
@MainActor
func shrinkStillShrinksOrdinaryStereo() async throws {
    var hissState: UInt64 = 7
    let hiss: [Float] = (0..<a16.count).map { _ in
        hissState = hissState &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: hissState >> 11) % 2_001 - 1_000) / 1_000 * 0.000_5
    }
    let controls: [(String, [[Float]])] = [
        ("a voice per channel", [a16, b16]),
        ("identical channels", [a16, a16]),
        ("panned, both voices on both sides", [mix(scaled(a16, 0.7), scaled(b16, 0.3)), mix(scaled(a16, 0.3), scaled(b16, 0.7))]),
        ("one voice centre, the other hard left", [mix(a16, b16), a16]),
        ("right silent", [a16, [Float](repeating: 0, count: a16.count)]),
        ("right silent but for DC", [a16, [Float](repeating: 0.02, count: a16.count)]),
        ("right silent but for hiss at −70 dBFS", [a16, hiss]),
        ("both clipped", [scaled(a16, 30).map { Swift.max(-1, Swift.min(1, $0)) }, scaled(b16, 30).map { Swift.max(-1, Swift.min(1, $0)) }]),
        ("a phone's spacing (0.44 ms), two talkers", [mix(a16, late(b16, 7)), mix(late(a16, 7), b16)]),
        ("a laptop's spacing (0.75 ms), one talker", [a16, late(a16, 12)]),
        ("a voice per channel, 1 s", [Array(a16.prefix(rate)), Array(b16.prefix(rate))]),
        ("a voice per channel, 0.3 s", [Array(a16.prefix(4_800)), Array(b16.prefix(4_800))]),
        // Without the coherence gate both are refused (round 4, gates/r4-08-mutant-coh0.txt): their bins are
        // opposite now and then, as unrelated sounds' are, never consistently.
        ("independent noise on each channel", [noise16(seed: 1, amplitude: 0.05), noise16(seed: 2, amplitude: 0.05)]),
        ("a voice beside itself 4 Hz higher", [a16, voice16(toneA, detune: 4)]),
    ]
    var refused: [String] = []
    for (label, channels) in controls {
        let outcome = try await shrinkWAV(channels)
        if outcome.kept || !outcome.alert.contains("Shrunk") { refused.append("\(label): \(outcome.alert)") }
    }
    // Other rates and a float WAV, a voice per channel.
    for wavRate in [8_000, 22_050, 96_000] {
        let a = voice16(toneA.filter { $0 < Double(wavRate) / 2 }, seconds: 4).map { $0 }
        let count = Int(4.0 * Double(wavRate))
        let resampled: [[Float]] = [a, voice16(toneB.filter { $0 < Double(wavRate) / 2 }, seconds: 4)].map { channel in
            (0..<count).map { channel[Swift.min(channel.count - 1, $0 * rate / wavRate)] }
        }
        let outcome = try await shrinkWAV(resampled, rate: wavRate)
        if outcome.kept || !outcome.alert.contains("Shrunk") { refused.append("\(wavRate) Hz: \(outcome.alert)") }
    }
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try fixtureFloatWAV([a16, b16], rate: rate).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    if !(f.model.alertMessage ?? "").contains("Shrunk") { refused.append("float WAV: \(f.model.alertMessage ?? "nil")") }
    print("F1001 round 4 controls: \(controls.count + 4 - refused.count) of \(controls.count + 4) shrunk")
    #expect(refused.isEmpty, "\(refused)")
}

// MARK: - Speech (the bench clips; gated, since they are not in git)

private func benchClip(_ name: String) throws -> [Float]? {
    guard let directory = ProcessInfo.processInfo.environment["F1001_BENCH_CLIPS"] else { return nil }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: directory).appendingPathComponent("\(name).wav"))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    try #require(file.processingFormat.sampleRate == 16_000)
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
}

private func benchSpeech(_ names: [String]) throws -> [Float] {
    var out: [Float] = []
    for name in names { out += try #require(try benchClip(name)).map { $0 * 0.5 }; out += [Float](repeating: 0, count: 1_600) }
    return out
}

@Test(
    "Speech: every mid/side pairing the reviews tried is kept, and speech that does not cancel shrinks (F1001 round 2)",
    .enabled(if: ProcessInfo.processInfo.environment["F1001_BENCH_CLIPS"] != nil)
)
@MainActor
func shrinkJudgesBenchSpeech() async throws {
    let names = ["en1", "en2", "en3", "en4", "zh1", "zh2", "cs1", "cs2", "cs3"]
    func trimmed(_ x: [Float], _ y: [Float]) -> ([Float], [Float]) {
        let n = Swift.min(x.count, y.count)
        return (Array(x.prefix(n)), Array(y.prefix(n)))
    }
    var positives: [(String, [[Float]])] = [], negatives: [(String, [[Float]])] = []
    for shift in 1...6 {
        let (x, y) = trimmed(try benchSpeech(Array(names.prefix(5))), try benchSpeech((0..<5).map { names[($0 + shift) % names.count] }))
        positives.append(("overlapping throughout, pairing \(shift)", midSide(x, y)))
        negatives.append(("a talker per channel, pairing \(shift)", [x, y]))
    }
    let (x, y) = trimmed(try benchSpeech(["en1", "en3", "zh1", "cs1", "en2"]), try benchSpeech(["en4", "zh2", "cs2", "en3", "zh3"]))
    for (db, k) in [("1", Float(0.891)), ("2", 0.794), ("3", 0.708), ("6", 0.5)] {
        positives.append(("the lane's pairing, side voice \(db) dB down", midSide(x, scaled(y, k))))
    }
    positives.append(("the lane's pairing, its first 10 s", midSide(Array(x.prefix(160_000)), Array(y.prefix(160_000)))))
    let interjection: [Float] = Array(try #require(try benchClip("en3")).prefix(19_200)).map { $0 * 0.5 }
    let lead: [Float] = Array(x.prefix(64_000)), tail: [Float] = Array(x.dropFirst(64_000).prefix(96_000))
    let middle: [Float] = lead + [Float](repeating: 0, count: interjection.count) + tail
    let side: [Float] = [Float](repeating: 0, count: lead.count) + interjection + [Float](repeating: 0, count: tail.count)
    positives.append(("a 1.2 s side interjection", midSide(middle, side)))
    negatives.append(("panned, both talkers on both sides", [mix(scaled(x, 0.7), scaled(y, 0.3)), mix(scaled(x, 0.3), scaled(y, 0.7))]))
    negatives.append(("a phone's spacing, two talkers", [mix(x, late(y, 7)), mix(late(x, 7), y)]))
    negatives.append(("one talker centre, one hard left", [mix(x, y), x]))
    negatives.append(("identical", [x, x]))
    var wrong: [String] = []
    for (label, channels) in positives {
        let outcome = try await shrinkWAV(channels)
        if !outcome.kept { wrong.append("DELETED \(label): \(outcome.alert)") }
    }
    for (label, channels) in negatives {
        let outcome = try await shrinkWAV(channels)
        if outcome.kept { wrong.append("REFUSED \(label): \(outcome.alert)") }
    }
    print("F1001 round 2 speech: \(positives.count) cancelling, \(negatives.count) ordinary, \(wrong.count) wrong")
    #expect(wrong.isEmpty, "\(wrong)")
}
