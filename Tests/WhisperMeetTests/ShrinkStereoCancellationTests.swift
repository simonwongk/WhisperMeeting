import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1001 — today's Shrink of a two-channel recording (not the held-back mixing path) encodes afconvert's
// mono mix, which sums the channels. A stereo file whose channels are mid/side (L = A + B, R = A − B), or
// L = B, R = A − B, loses B in that sum, and the checks before the original is deleted — the level of the
// whole copy and of each five seconds — still passed, because A is present (the review of Wave 7 lane S,
// S1 and S2: both originals deleted). Now the channels must not cancel each other when mixed into one — the
// user's rule of 2026-10-15, "Refuse any with cancellation" — and the copy must hold their mix before the
// original is removed; an interrupted Shrink's resume checks a two-channel leftover the same way. The reviews'
// own probes are in `ShrinkStereoCancellationProbeTests`. Driven through the calls the Shrink button makes,
// with the real encoder and decoder.

/// A voice-like sound: twelve tones, each swelling at its own rate (the lane's `fixtureVoice` shape).
private func stereoVoice(_ tones: [Double], amplitude: Double = 0.03, seconds: Double) -> [Float] {
    var sum = [Float](repeating: 0, count: Int(seconds * 48_000))
    for (index, tone) in tones.enumerated() {
        let rate = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        for (n, value) in fixtureTone(frequency: tone, amplitude: amplitude, seconds: seconds).enumerated() {
            sum[n] += value * Float(0.55 + 0.45 * sin(2 * Double.pi * rate * Double(n) / 48_000 + phase))
        }
    }
    return sum
}

private let toneA: [Double] = [311, 457, 619, 737, 911, 1_171, 1_409, 1_777, 2_389, 2_917, 3_571, 4_283]
private let toneB: [Double] = [353, 419, 541, 823, 953, 1_291, 1_613, 2_011, 2_557, 2_963, 3_803, 4_621]

/// How long the voices run: six seconds since the macos-15 suite reached its watchdog (CI fix after run
/// 38859340988). Nothing here needs more; each test's verdict, under each of the rule's mutants, was compared
/// at twelve seconds and at six and is the same.
private let voiceSeconds: Double = 6

/// Voices A and B, made once: generating one is slow in a test build, and almost every test here needs both.
private let voiceA = stereoVoice(toneA, seconds: voiceSeconds)
private let voiceB = stereoVoice(toneB, seconds: voiceSeconds)
private let silence = [Float](repeating: 0, count: voiceA.count)

private func sum(_ a: [Float], _ b: [Float], _ k: Float = 1) -> [Float] { zip(a, b).map { $0 + k * $1 } }

/// The review's two stereo probes, with voices A and B: S1, mid/side.
private let midSide: [[Float]] = [sum(voiceA, voiceB), sum(voiceA, voiceB, -1)]

/// S2: B alone on the left, A − B on the right.
private let leftCancels: [[Float]] = [voiceB, sum(voiceA, voiceB, -1)]

// MARK: - The review's probes (S1, S2)

@Test("A mid/side stereo recording, whose side voice cancels in the mono copy, keeps its original (F1001 S1)")
@MainActor
func shrinkKeepsAMidSideStereoRecording() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try fixturePolyWAV(midSide).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "the original holds the only copy of voice B: \(alert)")
    #expect((try? Data(contentsOf: f.recording)) == original, "\(alert)")
    #expect(!f.exists("recording.m4a"), "\(alert)")
    #expect(try f.hiddenTemps().isEmpty)
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("channel"), "the reason names the channel whose sound is missing: \(alert)")
}

@Test("A stereo recording whose left voice cancels against the right channel keeps its original (F1001 S2)")
@MainActor
func shrinkKeepsAStereoRecordingWhoseLeftVoiceCancels() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try fixturePolyWAV(leftCancels).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "the left channel's voice is only in the original: \(alert)")
    #expect((try? Data(contentsOf: f.recording)) == original, "\(alert)")
    #expect(!f.exists("recording.m4a"), "\(alert)")
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("left and right channels cancel each other"), "\(alert)")
}

// MARK: - The resume of an interrupted Shrink

/// A meeting whose index already names `recording.m4a`, made by today's encode from the two-channel
/// `recording.wav` still beside it: what a Shrink interrupted before its removals leaves.
@MainActor
private struct StereoResumeFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL

    init(channels: [[Float]], seconds: TimeInterval) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F1001-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let leftover = folder.appendingPathComponent("recording.wav")
        try fixturePolyWAV(channels).write(to: leftover)
        try AudioCompressor.compressSpeech(input: leftover, output: folder.appendingPathComponent("recording.m4a"),
                                           workingWAV: root.appendingPathComponent("work-\(UUID().uuidString).wav"))
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
        model.store.upsert(MeetingRecord(
            id: id, title: "Client call", duration: seconds,
            recordingPath: "Recordings/\(id.uuidString)/recording.m4a",
            status: .completed, transcriptText: "Hi."))
        model.availableBytesForShrink = { _ in .max }
    }

    var leftover: URL { folder.appendingPathComponent("recording.wav") }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A resume keeps a mid/side stereo leftover whose copy lost the side voice (F1001)")
@MainActor
func shrinkResumeKeepsAMidSideLeftover() async throws {
    let f = try await StereoResumeFixture(channels: midSide, seconds: voiceSeconds)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.leftover)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect((try? Data(contentsOf: f.leftover)) == original, "\(alert)")
    #expect(alert.contains("“recording.wav”, which the compressed copy replaced, was kept"), "\(alert)")
}

@Test("A resume keeps a stereo leftover whose left voice cancels in the copy (F1001)")
@MainActor
func shrinkResumeKeepsALeftCancellingLeftover() async throws {
    let f = try await StereoResumeFixture(channels: leftCancels, seconds: voiceSeconds)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect(alert.contains("its left and right channels cancel each other"), "\(alert)")
}

@Test("What Shrink says when a channel's sound is not shown in the copy, of a recording and of a resume's leftover (F1001)")
func shrinkSaysWhichChannelIsNotInTheCopy() {
    typealias Failure = AppModel.ShrinkFailure
    #expect(Failure.channelNotInCopy(.cancels(seconds: 4.096, band: 2)).errorDescription
        == "The recording's left and right channels cancel each other at about 0:04 when they are mixed into one, so a mono copy would lose sound; the recording is kept as it is.")
    #expect(Failure.channelNotInCopy(.missing(window: 1, channel: 1)).errorDescription
        == "Sound on the recording's right channel at about 0:05 is not in the compressed copy, because it cancels against the left channel when they are mixed into one; the recording is kept as it is.")
    #expect(Failure.channelNotInCopy(.copyMissing(window: 2)).errorDescription
        == "The compressed copy is missing sound the recording has at about 0:10, so the copy was discarded.")
    #expect(Failure.channelNotInCopy(.unmeasured(window: 0, channel: 1)).errorDescription
        == "The recording's right channel could not be checked against the compressed copy at about 0:00, so the copy was discarded.")
    #expect(Failure.channelNotInCopy(.unmeasured(window: 1, channel: nil)).errorDescription
        == "The recording's channels could not be checked against the compressed copy at about 0:05, so the copy was discarded.")
    #expect(Failure.leftoverChannelNotInCopy(name: "recording.wav", finding: .cancels(seconds: 0, band: 0)).errorDescription
        == "“recording.wav”, which the compressed copy replaced, was kept: its left and right channels cancel each other at about 0:00 when they are mixed into one, so a mono copy would lose sound.")
    #expect(Failure.leftoverChannelNotInCopy(name: "recording.wav", finding: .copyMissing(window: 0)).errorDescription
        == "“recording.wav”, which the compressed copy replaced, was kept: the compressed copy is missing sound it has at about 0:00.")
}

// MARK: - Ordinary stereo still shrinks (controls)

/// Records how often a `@Sendable` seam ran. A captured `var` cannot be mutated from one.
private final class SeamCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Shrinks a two-channel import written by `write` and requires that it was shrunk: the copy replaced the
/// original, the alert says so, and the channels were checked against the copy once.
@MainActor
private func expectShrunk(_ ext: String, seconds: Double = voiceSeconds, _ label: String,
                          write: (URL) async throws -> Void) async throws {
    let f = try await MixFixture(recordingExtension: ext, duration: seconds, write: write)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let calls = SeamCalls()
    let real = f.model.channelPresenceForShrink
    f.model.channelPresenceForShrink = { calls.add(); return try await real($0, $1) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(label): \(alert)")
    #expect(f.exists("recording.m4a"), "\(label): \(alert)")
    if ext != "m4a" { #expect(!f.exists("recording.\(ext)"), "\(label): \(alert)") }
    #expect(calls.value == 1, "\(label): the two channels were checked against the copy")
}

@Test("A stereo call with one voice per channel, as a two-track capture would lay it out, still shrinks (F1001 control)")
@MainActor
func shrinkStillShrinksAStereoCallWithAVoicePerChannel() async throws {
    try await expectShrunk("wav", "a voice per channel") { url in
        try fixturePolyWAV([voiceA, voiceB]).write(to: url)
    }
}

@Test("A stereo recording with one silent channel still shrinks (F1001 control)")
@MainActor
func shrinkStillShrinksAStereoRecordingWithASilentChannel() async throws {
    try await expectShrunk("wav", "right silent") { url in
        try fixturePolyWAV([voiceA, silence]).write(to: url)
    }
    try await expectShrunk("wav", "left silent") { url in
        try fixturePolyWAV([silence, voiceB]).write(to: url)
    }
}

@Test("A stereo link import, an AAC download with the same voice on both channels, still shrinks (F1001 control)")
@MainActor
func shrinkStillShrinksAStereoLinkImport() async throws {
    try await expectShrunk("m4a", "stereo AAC download") { url in
        let other: [Float] = voiceB.map { $0 / 3 }
        let left: [Float] = sum(voiceA, other)
        let right: [Float] = sum(voiceA.map { $0 * 0.8 }, other, -0.5)
        try await writeFixtureRawTracks(to: url, [[left, right]])
    }
}

@Test("A stereo music or movie import with correlated channels still shrinks (F1001 control)")
@MainActor
func shrinkStillShrinksACorrelatedStereoMovie() async throws {
    // A chord panned a little, one side 3 ms late (a widening), in a movie container and an MPEG-4 one.
    // Only the outcome is pinned: macOS 15 reads AVAssetWriter `.mov` files with different track timing.
    let chord = stereoVoice([196, 247, 294, 392, 494, 587, 784, 988, 1_175, 1_568, 1_976, 2_349], amplitude: 0.04, seconds: voiceSeconds)
    let late: [Float] = [Float](repeating: 0, count: 144) + Array(chord.dropLast(144))
    let left: [Float] = chord.map { $0 * 0.9 }
    let right: [Float] = late.map { $0 * 0.7 }
    for ext in ["mov", "mp4"] {
        try await expectShrunk(ext, "correlated music, .\(ext)") { url in
            try await writeFixtureRawTracks(to: url, [[left, right]])
        }
    }
}

@Test("A capture's mono recording, both tracks mixed into it, shrinks as before and is never checked channel by channel (F1001 control)")
@MainActor
func shrinkLeavesAMonoCaptureAsItWas() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1001-capture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The capture's rule: the microphone's and the system audio's voices summed at 0.95.
    let seconds = voiceSeconds
    let mixed: [Float] = sum(voiceA, voiceB).map { $0 * 0.95 }
    try WAVWriter.wavData(from: mixed, sampleRate: 48_000).write(to: folder.appendingPathComponent("meeting.wav"))
    let frames = Int(seconds * 48_000)
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try Data(count: frames * 4).write(to: folder.appendingPathComponent(name))
    }
    try Data("""
        {"systemAudio":{"file":"system-audio.f32","frameCount":\(frames)},
         "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(frames)}}
        """.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
    model.store.upsert(MeetingRecord(id: id, title: "Weekly sync", duration: seconds,
                                     recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
                                     status: .completed, transcriptText: "Hi."))
    model.availableBytesForShrink = { _ in .max }
    let calls = SeamCalls()
    model.channelPresenceForShrink = { _, _ in calls.add(); throw CocoaError(.fileReadUnknown) }

    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    await model.performShrink(confirmed: true)?.value

    let alert = model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.m4a").path), "\(alert)")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.wav").path), "\(alert)")
    #expect(calls.value == 0, "a mono recording has no channels to check against each other")
}

@Test("A mono import shrinks as before and is never checked channel by channel (F1001 control)")
@MainActor
func shrinkLeavesAMonoImportAsItWas() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try fixturePolyWAV([voiceA]).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let calls = SeamCalls()
    f.model.channelPresenceForShrink = { _, _ in calls.add(); throw CocoaError(.fileReadUnknown) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(!f.exists("recording.wav") && f.exists("recording.m4a"), "\(alert)")
    #expect(calls.value == 0)
}

@Test("A resume still removes an ordinary stereo leftover its copy holds, and a mono one unchecked (F1001 control)")
@MainActor
func shrinkResumeStillRemovesOrdinaryLeftovers() async throws {
    let stereo = try await StereoResumeFixture(
        channels: [voiceA, voiceB], seconds: voiceSeconds)
    defer { try? FileManager.default.removeItem(at: stereo.root) }
    let stereoCalls = SeamCalls()
    let real = stereo.model.channelPresenceForShrink
    stereo.model.channelPresenceForShrink = { stereoCalls.add(); return try await real($0, $1) }
    await stereo.shrink()
    let stereoAlert = stereo.model.alertMessage ?? "nil"
    #expect(!stereo.exists("recording.wav") && stereo.exists("recording.m4a"), "\(stereoAlert)")
    #expect(stereoAlert.contains("Shrunk"), "\(stereoAlert)")
    #expect(stereoCalls.value == 1)

    let mono = try await StereoResumeFixture(channels: [voiceA], seconds: voiceSeconds)
    defer { try? FileManager.default.removeItem(at: mono.root) }
    let monoCalls = SeamCalls()
    mono.model.channelPresenceForShrink = { _, _ in monoCalls.add(); throw CocoaError(.fileReadUnknown) }
    await mono.shrink()
    let monoAlert = mono.model.alertMessage ?? "nil"
    #expect(!mono.exists("recording.wav") && mono.exists("recording.m4a"), "\(monoAlert)")
    #expect(monoCalls.value == 0)
}

@Test("A copy a little shorter than a recording whose last window is short still has every window measured (F1001)")
func channelPresenceMeasuresARecordingPastItsCopysEnd() async throws {
    // 5.05 s of a voice per channel, its copy made from the first 5 s: within the length check's half
    // second, and the recording's last window, [5, 5.05), lies past the copy's end. It is still measured
    // against the mix — that needs no copy — and has no mix measured against the copy, so nothing refuses it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1001-short-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let channels: [[Float]] = [Array(voiceA.prefix(242_400)), Array(voiceB.prefix(242_400))]
    let original = root.appendingPathComponent("recording.wav"), shorter = root.appendingPathComponent("shorter.wav")
    try fixturePolyWAV(channels).write(to: original)
    try fixturePolyWAV(channels.map { Array($0.prefix(5 * 48_000)) }).write(to: shorter)
    let copy = root.appendingPathComponent("copy.m4a")
    try AudioCompressor.compressSpeech(input: shorter, output: copy, workingWAV: root.appendingPathComponent("work.wav"))

    let native = try DecodedAudio.fullyDecoded(of: original)
    try #require(native.channelWindowLevels.map(\.count) == [2, 2], "fixture: a second, short window")
    let presence = try await RecordingMixer.channelPresence(of: original, against: copy)
    #expect(presence.mix.count >= 2)
    #expect((presence.stretches.last?.start ?? 0) + 0.512 > 5.05, "the last stretch reaches the recording's end")
    #expect(RecordingMixPlan.firstChannelNotInCopy(presence, nativeChannelWindows: native.channelWindowLevels) == nil,
            "\(presence)")
}

// MARK: - Fail-closed

@Test("A stereo recording whose channels cannot be measured against the copy keeps its original (F1001)")
@MainActor
func shrinkKeepsAStereoRecordingItCannotMeasure() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
        try fixturePolyWAV([voiceA, voiceB]).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.channelPresenceForShrink = { _, _ in throw CocoaError(.fileReadUnknown) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav") && !f.exists("recording.m4a"), "\(alert)")
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("could not be read to check the compressed copy"), "\(alert)")
}

@Test("A stereo recording measured with the wrong number of channels, or not a number, keeps its original (F1001)")
@MainActor
func shrinkKeepsAStereoRecordingMeasuredWrongly() async throws {
    typealias Measure = RecordingMixPlan.ChannelPresence.Measure
    let good = Measure(energy: 1, missing: 0)
    let stretches: [RecordingMixPlan.ChannelPresence.Stretch] = stride(from: 0.0, to: 12, by: 0.512).map {
        .init(start: $0, level: 0.1, bands: [Measure](repeating: good, count: RecordingMixPlan.cancellationBands.count - 1))
    }
    let wrong: [RecordingMixPlan.ChannelPresence] = [
        .init(channels: 1, stretches: stretches, mix: [good, good, good], channelWindows: [[good, good], [good, good], [good, good]]),
        .init(channels: 2, stretches: stretches.enumerated().map { index, stretch in
            var bad = stretch
            if index == 12 { bad.bands[2] = Measure(energy: .nan, missing: 0) }
            return bad
        }, mix: [good, good, good], channelWindows: [[good, good], [good, good], [good, good]]),
        .init(channels: 2, stretches: Array(stretches.prefix(9)), mix: [good], channelWindows: [[good, good]]),
    ]
    for presence in wrong {
        let f = try await MixFixture(recordingExtension: "wav", duration: voiceSeconds) { url in
            try fixturePolyWAV([voiceA, voiceB]).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.channelPresenceForShrink = { _, _ in presence }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(f.exists("recording.wav") && !f.exists("recording.m4a"), "\(alert)")
        #expect(alert.contains("could not be checked against the compressed copy"), "\(alert)")
    }
}

@Test("A resume keeps a stereo leftover whose channels cannot be measured against the copy (F1001)")
@MainActor
func shrinkResumeKeepsAStereoLeftoverItCannotMeasure() async throws {
    let f = try await StereoResumeFixture(
        channels: [voiceA, voiceB], seconds: voiceSeconds)
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.channelPresenceForShrink = { _, _ in throw CocoaError(.fileReadUnknown) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect(alert.contains("“recording.wav”, which the compressed copy replaced, could not be checked against the copy, so it was kept."),
            "\(alert)")
}

// MARK: - Ten ffmpeg-made stereo files in a row

/// Writes stereo with the installed ffmpeg from a lavfi source.
private func ffmpegStereo(_ ffmpeg: URL, source: String, codec: [String], to url: URL) throws {
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", source] + codec + [url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "ffmpeg: \(String(decoding: output, as: UTF8.self))")
}

@Test(
    "Ten ordinary stereo files made by the installed ffmpeg shrink, none refused (F1001 control)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
@MainActor
func shrinkStillShrinksTenFFmpegStereoFiles() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let swell = { (f: Int, r: Int) in "0.1*sin(2*PI*\(f)*t)*(0.55+0.45*sin(2*PI*\(r)*t))" }
    let exprA = [220, 330, 470, 610, 890, 1_210].map { swell($0, 3) }.joined(separator: "+")
    let exprB = [260, 390, 520, 740, 980, 1_460].map { swell($0, 5) }.joined(separator: "+")
    let sources: [(String, String)] = [
        ("a voice per channel", "aevalsrc=\(exprA)|\(exprB):s=48000:d=12"),
        ("one voice, correlated", "aevalsrc=\(exprA)|0.7*(\(exprA)):s=48000:d=12"),
        ("right silent", "aevalsrc=\(exprA)|0:s=48000:d=12"),
        ("a voice per channel, echoed", "aevalsrc=\(exprA)|\(exprB):s=48000:d=12,aecho=0.8:0.6:40|70:0.4|0.3"),
        ("pink noise, partly correlated", "anoisesrc=c=pink:a=0.2:d=12:r=48000,pan=stereo|c0=c0|c1=0.6*c0"),
    ]
    let codecs: [(String, [String])] = [("wav", ["-c:a", "pcm_s16le"]), ("m4a", ["-c:a", "aac", "-b:a", "192k"])]
    var refused: [String] = []
    for (label, source) in sources {
        for (ext, codec) in codecs {
            let f = try await MixFixture(recordingExtension: ext, duration: 12) { url in
                try ffmpegStereo(ffmpeg, source: source, codec: codec, to: url)
            }
            defer { try? FileManager.default.removeItem(at: f.root) }
            #expect(DecodedAudio.channelCount(of: f.recording) == 2, "\(label), .\(ext)")
            await f.shrink()
            let alert = f.model.alertMessage ?? "nil"
            if !alert.contains("Shrunk") { refused.append("\(label), .\(ext): \(alert)") }
        }
    }
    print("F1001 ffmpeg stereo: \(sources.count * codecs.count - refused.count) of \(sources.count * codecs.count) shrunk")
    #expect(refused.isEmpty, "\(refused)")
}
