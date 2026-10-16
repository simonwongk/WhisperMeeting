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

/// A voice-like sound at 16 kHz: twelve tones, each swelling at its own rate.
private func voice16(_ tones: [Double], amplitude: Double = 0.03, seconds: Double = 12) -> [Float] {
    let count = Int(seconds * Double(rate))
    var out = [Float](repeating: 0, count: count)
    for (index, tone) in tones.enumerated() {
        let swell = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        let step = 2 * Double.pi * tone / Double(rate), swellStep = 2 * Double.pi * swell / Double(rate)
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

// MARK: - Every review probe keeps its original (CI-safe, synthetic)

@Test("Every channel cancellation the reviews of F1001 made deletes nothing now (F1001 round 2)")
@MainActor
func shrinkKeepsEveryCancellationTheReviewsMade() async throws {
    // F2-3: a loud chord, the same on both channels, then mid/side 22 dB quieter.
    var loudThenQuiet = midSide(scaled(a16, 0.08), scaled(b16, 0.08))
    let chord = voice16([196, 294, 392, 587, 784, 1_175], amplitude: 0.12, seconds: 4)
    for n in chord.indices { loudThenQuiet[0][n] = chord[n]; loudThenQuiet[1][n] = chord[n] }
    let probes: [(String, [[Float]])] = [
        ("side voice 3 dB down throughout (review 2's near-bound pin)", midSide(a16, scaled(b16, 0.708))),
        ("side voice 6 dB down throughout (review 1's miss)", midSide(a16, scaled(b16, 0.5))),
        ("side voice alone for 1.0 s", midSide(gated(a16, [(0, 2), (3, 12)]), gated(b16, [(2, 3)]))),
        ("side voice alone for 0.6 s", midSide(gated(a16, [(0, 2), (2.6, 12)]), gated(b16, [(2, 2.6)]))),
        ("side voice alone for 2.4 s across 0:05", midSide(gated(a16, [(0, 3.8), (6.2, 12)]), gated(b16, [(3.8, 6.2)]))),
        ("side voice for 2 s over the middle one", midSide(a16, gated(b16, [(4, 6)]))),
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

@Test("A WAV whose two channels are marked centre and LFE, or anything but left and right, is kept (F1001 round 2)")
@MainActor
func shrinkKeepsAWAVWhoseChannelsAreNotLeftAndRight() async throws {
    // Review 1: afconvert's mix follows the mask and drops the LFE channel, here a voice 12 dB down.
    let quietB = scaled(b16, 0.25)
    for (name, mask) in [("centre and LFE", UInt32(0x4 | 0x8)), ("no positions", UInt32(0)), ("back left and right", UInt32(0x10 | 0x20))] {
        let outcome = try await shrinkWAV([a16, quietB], mask: mask)
        #expect(outcome.kept, "\(name): \(outcome.alert)")
        #expect(outcome.alert.contains("marks its two channels as something other than left and right"), "\(name): \(outcome.alert)")
    }
    // Marked front left and front right, it shrinks as a plain WAV does.
    let plain = try await shrinkWAV([a16, quietB], mask: 0x3)
    #expect(!plain.kept && plain.alert.contains("Shrunk"), "\(plain.alert)")
}

@Test("A link import's stereo download beside its mono WAV is not deleted when its channels cancel (F1001 round 2, F2-1)")
@MainActor
func shrinkKeepsADownloadWhoseChannelsCancelBesideItsMonoWAV() async throws {
    for ext in ["m4a", "caf"] {
        // The folder an interrupted link import leaves: the download, and ffmpeg's `-ac 1` WAV made from it.
        let downloadChannels = midSide(a16, b16)
        let f = try await MixFixture(recordingExtension: "wav", duration: 12) { url in
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
        let f = try await MixFixture(recordingExtension: ext, duration: 12) { url in
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
    let f = try await MixFixture(recordingExtension: "wav", duration: 12) { url in
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
    model.store.upsert(MeetingRecord(id: id, title: "Client call", duration: 12,
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
    let f = try await MixFixture(recordingExtension: "wav", duration: 12) { url in
        try fixtureFloatWAV([a16, b16], rate: rate).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.shrink()
    if !(f.model.alertMessage ?? "").contains("Shrunk") { refused.append("float WAV: \(f.model.alertMessage ?? "nil")") }
    print("F1001 round 2 controls: \(controls.count + 4 - refused.count) of \(controls.count + 4) shrunk")
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
