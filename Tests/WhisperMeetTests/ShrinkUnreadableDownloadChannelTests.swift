import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1004 — a link import's download that AVFoundation cannot read (YouTube's usual Opus in WebM) sits beside the
// mono `recording.wav` ffmpeg extracted from it with `-ac 1`. F1001 checks a download macOS can read against the
// copy before Shrink deletes it, because a mono mix loses a voice in opposite polarity on the two channels; a WebM
// went on F911's length check alone, in a resume and beside the WAV alike, and was deleted with its second voice.
// Shrink now decodes such a download with the installed ffmpeg and checks its channels as it checks any stereo
// file, and keeps it when it cannot. The decode is a seam: here it writes the WAV the real ffmpeg would, so these
// run on CI (no ffmpeg there); the last test, gated, runs the real one on a real WebM/Opus file.

/// A voice-like sound: tones, each swelling at its own rate.
private func voice(_ tones: [Double], seconds: Double, amplitude: Double = 0.03) -> [Float] {
    var sum = [Float](repeating: 0, count: Int(seconds * 48_000))
    for (index, tone) in tones.enumerated() {
        let rate = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        for n in sum.indices {
            let t = Double(n) / 48_000
            sum[n] += Float(amplitude * sin(2 * Double.pi * tone * t) * (0.55 + 0.45 * sin(2 * Double.pi * rate * t + phase)))
        }
    }
    return sum
}

private let seconds: Double = 6
private let voiceA = voice([311, 457, 619, 737, 911, 1_171, 1_409, 1_777, 2_389, 2_917, 3_571, 4_283], seconds: seconds)
private let voiceB = voice([353, 419, 541, 823, 953, 1_291, 1_613, 2_011, 2_557, 2_963, 3_803, 4_621], seconds: seconds)
private func add(_ a: [Float], _ b: [Float], _ k: Float = 1) -> [Float] { zip(a, b).map { $0 + k * $1 } }

/// Mid/side: B is in opposite polarity on the two channels, so ffmpeg's `-ac 1` mix holds A alone.
private let midSide: [[Float]] = [add(voiceA, voiceB), add(voiceA, voiceB, -1)]
/// A voice per channel: the mix holds both.
private let ordinary: [[Float]] = [voiceA, voiceB]

/// What ffmpeg's `-ac 1` extraction makes of two channels: their mean.
private func monoOf(_ channels: [[Float]]) -> [Float] { zip(channels[0], channels[1]).map { ($0 + $1) / 2 } }

/// Bytes AVFoundation cannot open, standing for a WebM/Opus download.
private let webm = Data(repeating: 0x1A, count: 4_096)

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A link import's folder: the download beside the mono WAV extracted from it, indexed against the WAV — or, for
/// `resume`, against the `recording.m4a` an interrupted Shrink already made from that WAV, the WAV and the download
/// still beside it. The download's decode writes `decoded` (nil: no ffmpeg, it throws).
@MainActor
private struct UnreadableDownloadFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL
    let decodes = Calls()
    let measures = Calls()

    init(download channels: [[Float]], decoded: [[Float]]?, resume: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F1004-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("recording.wav")
        try fixturePolyWAV([monoOf(channels)]).write(to: wav)
        try webm.write(to: folder.appendingPathComponent("recording.webm"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
        if resume {
            try AudioCompressor.compressSpeech(input: wav, output: folder.appendingPathComponent("recording.m4a"),
                                               workingWAV: root.appendingPathComponent("work-\(UUID().uuidString).wav"))
        }
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
        model.store.upsert(MeetingRecord(
            id: id, title: "Conference talk", duration: seconds,
            recordingPath: "Recordings/\(id.uuidString)/recording.\(resume ? "m4a" : "wav")",
            status: .completed, transcriptText: "Hi.",
            recoverySource: RecoveredRecording.Source.importedRecording.rawValue))
        model.availableBytesForShrink = { _ in .max }
        // F962's measurement of a download AVAudioFile cannot read: as long as the WAV.
        model.measureDownloadForShrink = { _ in seconds }
        let decodes = decodes
        model.decodeUnreadableForShrink = { input, output in
            decodes.add()
            #expect(input.lastPathComponent == "recording.webm")
            guard let decoded else { throw InterruptedLinkImportExtraction.ChannelCheckDecodeError.ffmpegMissing }
            try fixturePolyWAV(decoded).write(to: output)
        }
        let measures = measures
        let real = model.channelPresenceForShrink
        model.channelPresenceForShrink = { measures.add(); return try await real($0, $1) }
    }

    var download: URL { folder.appendingPathComponent("recording.webm") }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    func temps() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".shrink-") }
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A WebM download whose channels cancel, beside the mono WAV extracted from it, is not deleted (F1004)")
@MainActor
func shrinkKeepsAnUnreadableDownloadWhoseChannelsCancel() async throws {
    let f = try UnreadableDownloadFixture(download: midSide, decoded: midSide)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: f.download)) == webm, "the download holds the only copy of voice B: \(alert)")
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("also holds “recording.webm”, which shrinking would delete"), "\(alert)")
    #expect(f.decodes.value == 1)
    let fTemps = try f.temps()
    #expect(fTemps.isEmpty, "the decode's WAV was left: \(fTemps)")
}

@Test("A WebM download Shrink cannot decode, with no ffmpeg installed, is kept and nothing is removed (F1004)")
@MainActor
func shrinkKeepsAnUnreadableDownloadItCannotDecode() async throws {
    let f = try UnreadableDownloadFixture(download: ordinary, decoded: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: f.download)) == webm, "\(alert)")
    #expect(f.exists("recording.wav") && !f.exists("recording.m4a"), "\(alert)")
    #expect(alert.contains("also holds “recording.webm”, which shrinking would delete, and it could not be checked"), "\(alert)")
}

@Test("An ordinary stereo WebM download beside its mono WAV is still removed, once its channels are checked (F1004 control)")
@MainActor
func shrinkStillRemovesAnOrdinaryUnreadableDownload() async throws {
    let f = try UnreadableDownloadFixture(download: ordinary, decoded: ordinary)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(!f.exists("recording.webm") && !f.exists("recording.wav") && f.exists("recording.m4a"), "\(alert)")
    #expect(f.decodes.value == 1)
    #expect(f.measures.value == 1, "the download's two channels were checked against the copy")
    let fTemps = try f.temps()
    #expect(fTemps.isEmpty, "\(fTemps)")
}

@Test("A mono WebM download is decoded, has no channels to check against each other, and is removed (F1004 control)")
@MainActor
func shrinkRemovesAMonoUnreadableDownload() async throws {
    let mono: [[Float]] = [monoOf(ordinary)]
    let f = try UnreadableDownloadFixture(download: ordinary, decoded: mono)
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(!f.exists("recording.webm"), "\(alert)")
    #expect(f.measures.value == 0)
}

@Test("A WebM download decoded to more than two channels is kept, since nothing checks them against the copy (F1004)")
@MainActor
func shrinkKeepsAnUnreadableDownloadOfMoreChannels() async throws {
    let f = try UnreadableDownloadFixture(download: ordinary, decoded: [voiceA, voiceB, voiceA])
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: f.download)) == webm, "\(alert)")
    #expect(alert.contains("could not be checked"), "\(alert)")
}

@Test("A download AVFoundation opens but lists no audio track for, or a track of no channels, is decoded and checked too (F1004 round 2)")
@MainActor
func shrinkChecksADownloadWhoseTracksShowNoChannels() async throws {
    // Review 1 of Wave 8 lane A, finding 1: an MP3 in MP4 opens, and AVFoundation lists no audio track in it (`[]`,
    // not nil), so it went to none of the channel checks and was removed on its length alone.
    for (label, tracks) in [("no audio track", [RecordingMixPlan.Track]()), ("a track of no channels", [RecordingMixPlan.Track(channels: 0)])] {
        let f = try UnreadableDownloadFixture(download: midSide, decoded: midSide)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let real = f.model.audioTracksForShrink
        f.model.audioTracksForShrink = { url in url.pathExtension == "webm" ? tracks : await real(url) }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect((try? Data(contentsOf: f.download)) == webm, "\(label): the download holds the only copy of voice B: \(alert)")
        if tracks.isEmpty {
            #expect(alert.contains("also holds “recording.webm”, which shrinking would delete"), "\(label): \(alert)")
            #expect(f.decodes.value == 1, "\(label)")
        }
        // A track of no channels is refused before any encode already (F955's plan cannot mix it); kept either way.
    }
}

@Test("A download whose decode comes out shorter than its measured length is kept, not judged on what was decoded (F1004 round 2)")
@MainActor
func shrinkKeepsADownloadWhoseDecodeIsShort() async throws {
    // Review 2 of Wave 8 lane A, finding 4b: ffmpeg can exit 0 on a decode that stopped early, and a mono or short
    // decode then said nothing about the rest. The download measures six seconds; its decode holds one.
    let short: [[Float]] = [Array(monoOf(ordinary).prefix(48_000))]
    for resume in [false, true] {
        let f = try UnreadableDownloadFixture(download: ordinary, decoded: short, resume: resume)
        defer { try? FileManager.default.removeItem(at: f.root) }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect((try? Data(contentsOf: f.download)) == webm, "resume \(resume): \(alert)")
        #expect(alert.contains("could not be checked"), "resume \(resume): \(alert)")
    }
}

// F1058 — the check refused a decode shorter than the measured download and trusted a longer one: a download measured
// at six seconds that decodes to twelve is not the file that was measured, or the decode is not of it, and its
// channels then say nothing about the six seconds the plan weighed. Refused both ways now.
@Test("A download whose decode comes out longer than its measured length is kept too (F1058)")
@MainActor
func shrinkKeepsADownloadWhoseDecodeIsLong() async throws {
    let long: [[Float]] = [monoOf(ordinary) + monoOf(ordinary)]
    for resume in [false, true] {
        let f = try UnreadableDownloadFixture(download: ordinary, decoded: long, resume: resume)
        defer { try? FileManager.default.removeItem(at: f.root) }

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect((try? Data(contentsOf: f.download)) == webm, "resume \(resume): \(alert)")
        #expect(alert.contains("could not be checked"), "resume \(resume): \(alert)")
    }
}

@Test("A resume checks the free space a download's decode needs before decoding it (F1004 round 2)")
@MainActor
func shrinkResumeChecksFreeSpaceBeforeDecoding() async throws {
    // Review 2 of Wave 8 lane A, finding 4a: the encode counted the decode's 64 kB a second; a resume decoded with no
    // look at the free space, and could fill the volume before ffmpeg failed.
    let f = try UnreadableDownloadFixture(download: ordinary, decoded: ordinary, resume: true)
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.availableBytesForShrink = { _ in 1_000 }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: f.download)) == webm, "\(alert)")
    #expect(f.decodes.value == 0, "decoded with no room for it")
    #expect(alert.contains("Shrinking needs about"), "\(alert)")
}

@Test("A resume keeps a WebM leftover whose channels cancel, and still removes an ordinary one (F1004)")
@MainActor
func shrinkResumeChecksAnUnreadableLeftover() async throws {
    let kept = try UnreadableDownloadFixture(download: midSide, decoded: midSide, resume: true)
    defer { try? FileManager.default.removeItem(at: kept.root) }
    await kept.shrink()
    let keptAlert = kept.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: kept.download)) == webm, "\(keptAlert)")
    #expect(keptAlert.contains("“recording.webm”, which the compressed copy replaced, was kept"), "\(keptAlert)")
    #expect(kept.decodes.value == 1)

    let removed = try UnreadableDownloadFixture(download: ordinary, decoded: ordinary, resume: true)
    defer { try? FileManager.default.removeItem(at: removed.root) }
    await removed.shrink()
    let removedAlert = removed.model.alertMessage ?? "nil"
    #expect(removedAlert.contains("Shrunk"), "\(removedAlert)")
    #expect(!removed.exists("recording.webm") && !removed.exists("recording.wav"), "\(removedAlert)")
    let removedTemps = try removed.temps()
    #expect(removedTemps.isEmpty, "\(removedTemps)")

    let undecodable = try UnreadableDownloadFixture(download: ordinary, decoded: nil, resume: true)
    defer { try? FileManager.default.removeItem(at: undecodable.root) }
    await undecodable.shrink()
    let undecodableAlert = undecodable.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: undecodable.download)) == webm, "\(undecodableAlert)")
    #expect(undecodableAlert.contains("could not be checked against the copy, so it was kept"), "\(undecodableAlert)")
}

@Test("The decode's ffmpeg arguments keep every channel, take every audio stream, and name both paths as files (F1004)")
func channelCheckDecodeArgumentsArePinned() {
    #expect(MediaDownloadArguments.decodeForChannelCheck(input: "/a/recording.webm", output: "/a/.shrink-x.wav")
        == ["-nostdin", "-y", "-loglevel", "repeat+info", "-i", "file:/a/recording.webm", "-vn", "-map", "0:a",
            "-c:a", "pcm_s16le", "-ar", "16000", "-f", "wav", "file:/a/.shrink-x.wav"])
}

// MARK: - The installed ffmpeg, on a real WebM/Opus file

private func runFFmpeg(_ ffmpeg: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "ffmpeg: \(String(decoding: output, as: UTF8.self))")
}

@Test(
    "With the installed ffmpeg, a real mid/side WebM/Opus download is kept and an ordinary one removed; a WebM of two streams is kept (F1004)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
@MainActor
func shrinkChecksARealWebMDownloadWithTheInstalledFFmpeg() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    for (label, channels, expectKept) in [("mid/side", midSide, true), ("a voice per channel", ordinary, false)] {
        let f = try UnreadableDownloadFixture(download: channels, decoded: nil)
        defer { try? FileManager.default.removeItem(at: f.root) }
        // The real download: Opus in WebM, made from the two channels; the WAV beside it, ffmpeg's `-ac 1` of it.
        let source = f.root.appendingPathComponent("source.wav")
        try fixturePolyWAV(channels).write(to: source)
        try runFFmpeg(ffmpeg, ["-i", source.path, "-c:a", "libopus", "-b:a", "128k", f.download.path])
        try runFFmpeg(ffmpeg, ["-i", f.download.path, "-ac", "1", "-c:a", "pcm_s16le", f.folder.appendingPathComponent("recording.wav").path])
        try #require(await RecordingMixer.tracks(of: f.download) == nil, "fixture: AVFoundation read the WebM")
        f.model.decodeUnreadableForShrink = { input, output in
            try await InterruptedLinkImportExtraction.decodeForChannelCheck(input, to: output, ffmpeg: ffmpeg)
        }
        let before = try Data(contentsOf: f.download)

        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        if expectKept {
            #expect((try? Data(contentsOf: f.download)) == before, "\(label): \(alert)")
            #expect(alert.contains("also holds “recording.webm”"), "\(label): \(alert)")
        } else {
            #expect(alert.contains("Shrunk") && !f.exists("recording.webm"), "\(label): \(alert)")
        }
        let fTemps = try f.temps()
        #expect(fTemps.isEmpty, "\(label): \(fTemps)")
    }
    let two = FileManager.default.temporaryDirectory.appendingPathComponent("F1004-two-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: two) }
    let streams = two.appendingPathComponent("two.webm"), output = two.appendingPathComponent("out.wav")
    try runFFmpeg(ffmpeg, ["-f", "lavfi", "-i", "sine=440:d=2", "-f", "lavfi", "-i", "sine=880:d=2",
                           "-map", "0", "-map", "1", "-c:a", "libopus", streams.path])
    await #expect(throws: InterruptedLinkImportExtraction.ChannelCheckDecodeError.self) {
        try await InterruptedLinkImportExtraction.decodeForChannelCheck(streams, to: output, ffmpeg: ffmpeg)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    await #expect(throws: InterruptedLinkImportExtraction.ChannelCheckDecodeError.ffmpegMissing) {
        try await InterruptedLinkImportExtraction.decodeForChannelCheck(streams, to: output, ffmpeg: nil)
    }
}
