import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F942 — a recording imported with several audio tracks (a call saved with one side per track) was
// transcribed from its first track only, with nothing said: Whisper's ffmpeg decode, Qwen's afconvert
// transcode and AVAudioFile each read track 1 (F801's probe). The same happened inside one track with
// more than two channels and no layout ("poly" WAVs), which afconvert's mix reduces to channel 1. The
// user's decision (2026-10-12): mix every track into one for transcription and for Shrink. These drive
// `executeEngine`, the one place every engine run is admitted (a full transcription, a second opinion,
// a segment re-run), with the engine stubbed so the test can listen to the file it was handed.

/// Records the URL each engine run was handed, and what that file held at the time.
private final class EngineInputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: URL, decoded: (rate: Double, channels: [[Float]])?)] = []
    func record(_ url: URL) {
        let decoded = try? fixtureDecode(url)
        lock.lock(); entries.append((url, decoded)); lock.unlock()
    }
    var all: [(url: URL, decoded: (rate: Double, channels: [[Float]])?)] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}

@MainActor
private func engineRun(on recording: URL, root: URL) async throws -> EngineInputLog {
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let log = EngineInputLog()
    model.runTranscriptionEngineOverride = { _, url in
        log.record(url)
        return TranscriptionResult(id: "stub", text: "Hi.", languageCode: "en", audioDuration: 4,
                                   confidence: nil, segments: [])
    }
    _ = try await model.executeEngine(MeetingTranscriptionSelection(engine: .whisperLarge, language: .automatic),
                                      on: recording)
    return log
}

private func scratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test("An import with two audio tracks reaches the engine as one mono recording holding both (F942)")
@MainActor
func engineHearsBothTracksOfATwoTrackImport() async throws {
    let root = try scratch("F942-engine"); defer { try? FileManager.default.removeItem(at: root) }
    // The quiet side on track 1, the loud one on track 2: before F942 the engine heard only the quiet one.
    let recording = root.appendingPathComponent("recording.mov")
    try await writeFixtureTracks(to: recording, [
        FixtureTrack(channels: [(300, 0.05)], seconds: 4),
        FixtureTrack(channels: [(800, 0.4)], seconds: 4),
    ])
    let original = try Data(contentsOf: recording)

    let log = try await engineRun(on: recording, root: root)

    let run = try #require(log.all.first)
    let heard = try #require(run.decoded, "the engine's input could be read")
    #expect(heard.channels.count == 1, "one mono signal, as every engine wants")
    #expect(heard.rate == 16_000)
    let mono = try #require(heard.channels.first)
    #expect(abs(Double(mono.count) / heard.rate - 4) < 0.05)
    // Both sides, each at nearly the level it was recorded at (the capture mixer's 0.95, F345).
    #expect(abs(fixtureToneAmplitude(mono, rate: heard.rate, frequency: 300) - 0.0475) < 0.005)
    #expect(abs(fixtureToneAmplitude(mono, rate: heard.rate, frequency: 800) - 0.38) < 0.02)
    #expect(try Data(contentsOf: recording) == original, "the recording is only read")
    #expect(!FileManager.default.fileExists(atPath: run.url.path), "the mix is removed once the engine is done")
}

@Test("A WAV with four channels and no layout reaches the engine with every channel in it (F942)")
@MainActor
func engineHearsEveryChannelOfAPolyWAV() async throws {
    let root = try scratch("F942-poly"); defer { try? FileManager.default.removeItem(at: root) }
    // A floor microphone and three interpreters, one tone each.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let recording = root.appendingPathComponent("recording.wav")
    try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 3) }).write(to: recording)

    let log = try await engineRun(on: recording, root: root)

    let run = try #require(log.all.first)
    let heard = try #require(run.decoded)
    #expect(heard.channels.count == 1)
    let mono = try #require(heard.channels.first)
    for tone in tones {
        #expect(abs(fixtureToneAmplitude(mono, rate: heard.rate, frequency: tone) - 0.19) < 0.01, "\(tone) Hz")
    }
}

@Test("A recording with one track of one or two channels is handed to the engine as it is (F942 control)")
@MainActor
func engineGetsAnOrdinaryRecordingAsItIs() async throws {
    let root = try scratch("F942-plain"); defer { try? FileManager.default.removeItem(at: root) }
    let mono = root.appendingPathComponent("meeting.wav")
    try WAVWriter.wavData(from: fixtureTone(frequency: 440, amplitude: 0.3, seconds: 1), sampleRate: 48_000).write(to: mono)
    let stereo = root.appendingPathComponent("recording.wav")
    try fixturePolyWAV([fixtureTone(frequency: 300, amplitude: 0.2, seconds: 1),
                        fixtureTone(frequency: 500, amplitude: 0.2, seconds: 1)]).write(to: stereo)
    let movie = root.appendingPathComponent("recording.mov")
    try await writeFixtureTracks(to: movie, [FixtureTrack(channels: [(300, 0.2), (500, 0.2)], seconds: 1)])

    for recording in [mono, stereo, movie] {
        let log = try await engineRun(on: recording, root: root)
        // The engines' own decodes mix one or two channels (ffmpeg's -ac 1, afconvert's --mix, F796).
        #expect(log.all.map(\.url) == [recording], "\(recording.lastPathComponent)")
    }
}

// Review of F942, R3: ffmpeg's MP4 and QuickTime muxer puts every audio track it writes in one alternate
// group and enables only the first, and so do tools built on it (OBS's ffmpeg output). F942 took any group
// for languages, so the ticket's own case — a call saved one side per track — was still transcribed from
// track 1 when ffmpeg made the file. Alternatives are now tracks of one group tagged with different
// languages; ffmpeg tags them `und`.
@Test("Tracks ffmpeg put in one alternate group, untagged, reach the engine mixed (F942 review R3)")
@MainActor
func engineHearsBothTracksOfAFileFFmpegGrouped() async throws {
    let root = try scratch("F942-R3"); defer { try? FileManager.default.removeItem(at: root) }
    let call = root.appendingPathComponent("call.mp4")
    try await writeFixtureTracks(to: call, [FixtureTrack(channels: [(300, 0.05)], seconds: 4),
                                            FixtureTrack(channels: [(800, 0.4)], seconds: 4)], alternates: true)

    let log = try await engineRun(on: call, root: root)

    let run = try #require(log.all.first)
    #expect(run.url != call, "mixed, not handed on as it is")
    let heard = try #require(run.decoded)
    let mono = try #require(heard.channels.first)
    #expect(fixtureToneAmplitude(mono, rate: heard.rate, frequency: 300) > 0.03)
    #expect(fixtureToneAmplitude(mono, rate: heard.rate, frequency: 800) > 0.3, "the disabled second track is heard")
}

// Review of F942, R1: the mixer compared its mix with the asset's duration, which counts a video track,
// so a movie whose picture runs more than half a second past its sound threw "stopped at 0:06 of 0:08" —
// on every engine run, where before F942 it transcribed. The audio tracks' own end is what a mix covers.
@Test("A movie whose picture runs past its sound is still transcribed, from the mix of its tracks (F942 review R1)")
@MainActor
func engineHearsAMovieWhosePictureOutlastsItsSound() async throws {
    let root = try scratch("F942-R1"); defer { try? FileManager.default.removeItem(at: root) }
    let twoTracks = root.appendingPathComponent("two.mp4")
    try await writeFixtureTracks(to: twoTracks, [FixtureTrack(channels: [(300, 0.05)], seconds: 6),
                                                 FixtureTrack(channels: [(800, 0.4)], seconds: 6)], videoSeconds: 8)
    let surround = root.appendingPathComponent("surround.mp4")
    // AAC 5.1 orders its channels C L R Ls Rs LFE, and its LFE channel carries only the lowest sound, so the
    // sixth tone is a low one, as an LFE track holds.
    let tones = [300.0, 500.0, 700.0, 900.0, 1_100.0, 60.0]
    try await writeFixtureTracks(to: surround, [FixtureTrack(channels: tones.map { ($0, 0.1) }, seconds: 6)], videoSeconds: 8)

    for (movie, heardTones) in [(twoTracks, [300.0, 800.0]), (surround, tones)] {
        let log = try await engineRun(on: movie, root: root)
        let run = try #require(log.all.first)
        let heard = try #require(run.decoded, "\(movie.lastPathComponent): the engine's input could be read")
        let mono = try #require(heard.channels.first)
        #expect(heard.channels.count == 1 && heard.rate == 16_000, "\(movie.lastPathComponent) is mixed")
        #expect(abs(Double(mono.count) / heard.rate - 6) < 0.1, "\(movie.lastPathComponent): the sound's length, not the picture's")
        for tone in heardTones {
            #expect(fixtureToneAmplitude(mono, rate: heard.rate, frequency: tone, from: 0.5, to: 5.5) > 0.01,
                    "\(movie.lastPathComponent): \(tone) Hz")
        }
    }
}

@Test("Every decode of a recording for listening is reached through the mixer, and no new one is added unseen (F942)")
func everyDecodeForListeningGoesThroughTheMixer() throws {
    // Derived, not restated: the files that hand a recording to a decoder that keeps one track are found
    // by searching the sources, so a new decode site fails here until someone routes it through the mix.
    var callers: Set<String> = []
    for directory in ["Sources/WhisperCore", "Sources/WhisperMeet"] {
        for file in try SourceAssertion.swiftFileURLs(under: directory) {
            let source = SourceAssertion.stripComments(try String(contentsOf: file, encoding: .utf8))
            if source.contains("transcodeToWAV(input:") || source.contains("decodeArguments(input:") {
                callers.insert(file.lastPathComponent)
            }
        }
    }
    // AudioTranscoder defines the transcode; AudioCompressor is Shrink's encode, which is handed the mix;
    // QwenASRClient and LocalWhisperClient are the engines, which `executeEngine` hands the mix; and
    // AppModel's is speaker analysis's own, which mixes first.
    let expected: Set<String> = ["AudioTranscoder.swift", "AudioCompressor.swift", "QwenASRClient.swift",
                                 "LocalWhisperClient.swift", "AppModel.swift"]
    #expect(callers == expected, "\(callers.sorted())")
    let app = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(app.contains("try await RecordingMixer.mixIfNeeded(url, into: mixDirectory)"), "executeEngine mixes")
    #expect(app.contains("try await RecordingMixer.mixIfNeeded(request.audioURL, into: workspace)"),
            "speaker analysis mixes before it transcodes")
    let shrink = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel+Shrink.swift")
    #expect(shrink.contains("let result = try await mix(recordingURL, mixWAV)"), "Shrink encodes the mix")
}
