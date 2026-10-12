import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F942, F953 — Shrink keeps one mono track. Since F801 it refused an import with several audio tracks,
// or with more than two channels, because its encode kept track 1 (or channel 1) and the rest would
// have been deleted with the original; F953 noted that this also refused positioned 5.1 audio. The
// user's decision (2026-10-12): mix every track into one, for transcription and for Shrink. Wave 6 built
// a Shrink that mixes every channel of every track into its copy and checks the copy against each of
// them; its second review found that check still deleting originals (D1, D2), so as shipped Shrink
// refuses every recording that needs mixing until F980 (`MeetingStoragePlan.shrinkMixesRecordings`, off).
// The tests up to the F980 section run that held-back path with the switch on (`mixing: true`), so F980
// starts from it; the F980 section runs the shipped refusal. Driven through the calls the Shrink button
// makes, with the real mixer, encoder and decoder.

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func set() { lock.lock(); called = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return called }
}

/// One imported meeting in a temp library: `Recordings/<id>/recording.<ext>`, as `importOne` lays it out.
@MainActor
private struct MixFixture {
    let root: URL
    let model: AppModel
    let id: UUID
    let folder: URL
    let recording: URL

    /// `mixing` sets `shrinkMixesRecordings`, the switch for Shrink of a recording that needs mixing: off
    /// as shipped (F980); on for the tests that run the held-back path.
    init(recordingExtension ext: String, duration: TimeInterval, mixing: Bool = false,
         write: (URL) async throws -> Void) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F942-shrink-\(UUID().uuidString)")
        id = UUID()
        folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recording = folder.appendingPathComponent("recording.\(ext)")
        try await write(recording)
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        model.store.upsert(MeetingRecord(
            id: id, title: "Client call", duration: duration,
            recordingPath: "Recordings/\(id.uuidString)/recording.\(ext)",
            status: .completed, transcriptText: "Hi."))
        // The free-space figure is the host's; these tests are about what is kept.
        model.availableBytesForShrink = { _ in .max }
        model.shrinkMixesRecordings = mixing
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func hiddenTemps() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".shrink-") }
    }

    func reason() async throws -> MeetingStoragePlan.Unavailability? {
        await model.refreshStorage(ids: [id])
        return model.shrinkUnavailability(for: try #require(model.store.meeting(id: id)))
    }

    func shrink() async {
        await model.refreshStorage(ids: [id])
        model.requestShrink(ids: [id])
        await model.performShrink(confirmed: true)?.value
    }

    /// The shrunk copy, decoded: one mono channel at 16 kHz.
    func copy() throws -> [Float] {
        let decoded = try fixtureDecode(folder.appendingPathComponent("recording.m4a"))
        #expect(decoded.channels.count == 1)
        #expect(decoded.rate == 16_000)
        return try #require(decoded.channels.first)
    }
}

@Test("An import with two audio tracks is shrunk into one copy holding both, stretch by stretch (F942)")
@MainActor
func shrinkMixesATwoTrackImport() async throws {
    // A call saved one side per track, the two sides taking turns: the quiet side for the first four
    // seconds, then the loud side.
    let f = try await MixFixture(recordingExtension: "mov", duration: 8, mixing: true) { url in
        try await writeFixtureTracks(to: url, [
            FixtureTrack(channels: [(300, 0.05)], seconds: 8, audibleTo: 4),
            FixtureTrack(channels: [(800, 0.4)], seconds: 8, audibleFrom: 4),
        ])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil, "the button is offered: the tracks are mixed, not lost")

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk “Client call”"), "\(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.mov"), "\(alert)")
    #expect(try f.hiddenTemps().isEmpty)
    let copy = try f.copy()
    // Each side where it spoke, at nearly the level it was recorded at (the capture mixer's 0.95).
    #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: 300, from: 0.5, to: 3.5) - 0.0475) < 0.006)
    #expect(fixtureToneAmplitude(copy, rate: 16_000, frequency: 800, from: 0.5, to: 3.5) < 0.005)
    #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: 800, from: 4.5, to: 7.5) - 0.38) < 0.03)
    #expect(fixtureToneAmplitude(copy, rate: 16_000, frequency: 300, from: 4.5, to: 7.5) < 0.005)
}

@Test("A WAV with four channels and no layout is shrunk with every channel in the copy (F942, F953)")
@MainActor
func shrinkMixesAFourChannelImport() async throws {
    // F801 review R5's fixture: four simultaneous feeds at one level, a floor microphone and three
    // interpreters. The encode once kept channel 1 and deleted the rest; then Shrink refused it.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await MixFixture(recordingExtension: "wav", duration: 6, mixing: true) { url in
        try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 6) }).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    #expect(f.exists("recording.m4a") && !f.exists("recording.wav"), "\(alert)")
    let copy = try f.copy()
    for tone in tones {
        // Averaged over the track's four channels (0.2 / 4), at the mix's 0.95.
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone) - 0.0475) < 0.005, "\(tone) Hz")
    }
}

@Test("A positioned 5.1 WAV is shrunk with all six channels in the copy, its LFE too (F953)")
@MainActor
func shrinkMixesAFivePointOneImport() async throws {
    let tones = [300.0, 500.0, 700.0, 900.0, 1_100.0, 1_300.0]
    let f = try await MixFixture(recordingExtension: "wav", duration: 6, mixing: true) { url in
        try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.1, seconds: 6) }, mask: 0x3F).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    for tone in tones {
        // Averaged over the track's six channels (0.1 / 6), at the mix's 0.95.
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone) - 0.0158) < 0.003, "\(tone) Hz")
    }
}

/// Four microphones of a panel, each speaker in turn for five seconds, every voice also reaching the
/// other three microphones about 15 dB down (an amplitude of 0.178 of its own).
private func panelChannels() -> [[Float]] {
    let tones = [300.0, 500.0, 700.0, 900.0], rate = 48_000.0, bleed = 0.178
    return (0..<4).map { mic in
        (0..<Int(20 * rate)).map { n in
            let t = Double(n) / rate, speaker = Swift.min(3, Int(t / 5))
            let level = speaker == mic ? 0.2 : 0.2 * bleed
            return Float(level * sin(2 * Double.pi * tones[speaker] * t))
        }
    }
}

// Review of F942, R2: the level, per-window and per-channel checks compare levels, and a level cannot show
// a track that is missing while another sounds over it. The review deleted an original with the real
// mixer — a stereo track whose channels are in opposite polarity sums to nothing — and with a mixer that
// drops a track (M8). Now Shrink fits the copy's waveform onto each track and channel, window by window,
// and refuses a track whose own channels cancel, so it keeps the original unless every track is shown.

@Test("A track whose channels cancel, under another track, is not deleted with the original (F942 review R2)")
@MainActor
func shrinkKeepsAnOriginalWhoseTrackCancels() async throws {
    // The review's probe B, through the real mixer.
    let f = try await MixFixture(recordingExtension: "mov", duration: 10, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2), (300, -0.2)], seconds: 10),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 10)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original, "the only copy of track 1's sound")
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty)
}

@Test("A mix that lost a track sounding under another is caught, and the original kept (F942 review R2, M8)")
@MainActor
func shrinkKeepsAnOriginalWhoseTrackTheMixLostUnderAnother() async throws {
    // The review's probe I: track 2 speaks over track 1, never alone.
    let f = try await MixFixture(recordingExtension: "mov", duration: 20, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 20),
                                               FixtureTrack(channels: [(800, 0.1)], seconds: 20, audibleFrom: 2, audibleTo: 18)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    // A mixer that loses the second track: it mixes a copy of the recording holding the first alone.
    let firstOnly = f.root.appendingPathComponent("first-only.mov")
    try await writeFixtureTracks(to: firstOnly, [FixtureTrack(channels: [(300, 0.2)], seconds: 20)])
    f.model.mixForShrink = { _, output in
        let result = try await RecordingMixer.mixEveryChannel(of: firstOnly, to: output)
        return RecordingMixer.Result(tracks: 2, channels: 2, duration: result.duration)
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
}

@Test("A mix that kept one of four channels sounding at once is caught, and the original kept (F942 review R2)")
@MainActor
func shrinkKeepsAnOriginalWhoseChannelsTheMixLostBesideOthers() async throws {
    // R5's four simultaneous feeds at one level, given to a mixer with R5's fault (afconvert keeps channel 1):
    // every level matches, so only a fit of each channel shows the other three gone.
    let tones = [300.0, 500.0, 700.0, 900.0]
    let f = try await MixFixture(recordingExtension: "wav", duration: 6, mixing: true) { url in
        try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 6) }).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.mixForShrink = { input, output in
        try AudioTranscoder.transcodeToWAV(input: input, output: output)
        return RecordingMixer.Result(tracks: 1, channels: 4, duration: 6)
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
}

@Test("A mix that lost a channel is caught where that channel speaks, and the original is kept (F942)")
@MainActor
func shrinkRefusesAMixThatLostAChannel() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: 20, mixing: true) { url in
        try fixturePolyWAV(panelChannels()).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    // A mixer with F801 review R5's fault: afconvert's mix of a WAV with more than two channels and no
    // layout keeps channel 1. Speakers 2-4 then survive only as their bleed into microphone 1, and over
    // all four channels that is enough for the whole-file and per-stretch levels (the copy's level
    // equals the original's, and each stretch keeps a third of it); only each channel's own level
    // shows that speaker 2 is missing from 0:05.
    f.model.mixForShrink = { input, output in
        try AudioTranscoder.transcodeToWAV(input: input, output: output)
        return RecordingMixer.Result(tracks: 1, channels: 4, duration: 20)
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed"), "\(alert)")
    #expect(alert.contains("at about 0:05") && alert.contains("the copy was discarded"), "speaker 2 starts at 0:05: \(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty, "the mix and the encode's temps are removed")
}

@Test("The same panel through the real mixer is shrunk with every speaker in the copy (F942 control)")
@MainActor
func shrinkMixesAPanelWhoseMicrophonesTakeTurns() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: 20, mixing: true) { url in
        try fixturePolyWAV(panelChannels()).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    for (speaker, tone) in [300.0, 500.0, 700.0, 900.0].enumerated() {
        let from = Double(speaker) * 5 + 0.5
        // The voice and its bleed into the other three microphones, averaged: 0.2 × (1 + 3 × 0.178) / 4 × 0.95.
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone, from: from, to: from + 4) - 0.0729) < 0.006,
                "speaker \(speaker + 1)")
    }
}

// Review of F942/F955, mutant M2: the checks judge the copy against each channel the recording was measured
// to have, so a decode that measured fewer channels than the mixer mixed leaves the rest unjudged — a lost
// channel there would pass. Nothing drove that guard; this decode measures one channel too few of a copy
// that is good, so only the guard can refuse it.
@Test("A recording measured with fewer channels than were mixed keeps its original (F942 review, M2)")
@MainActor
func shrinkKeepsAnOriginalMeasuredWithFewerChannelsThanMixed() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: 20, mixing: true) { url in
        try fixturePolyWAV(panelChannels()).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.model.decodeForShrink = { url in
        var decoded = try await DecodedAudio.fullyDecodedEveryTrack(of: url)
        if url.lastPathComponent == "recording.wav" { decoded.channelWindowLevels.removeLast() }
        return decoded
    }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("nothing was removed") && alert.contains("could not be read to check the compressed copy"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty)
}

@Test("A movie whose picture runs past its sound is shrunk from the mix of its tracks (F942 review R1)")
@MainActor
func shrinkMixesAMovieWhosePictureOutlastsItsSound() async throws {
    let f = try await MixFixture(recordingExtension: "mp4", duration: 8, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 6, audibleTo: 3),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 6, audibleFrom: 3)],
                                     videoSeconds: 8)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    #expect(fixtureToneAmplitude(copy, rate: 16_000, frequency: 300, from: 0.5, to: 2.5) > 0.1, "\(alert)")
    #expect(fixtureToneAmplitude(copy, rate: 16_000, frequency: 800, from: 3.5, to: 5.5) > 0.1, "\(alert)")
}

@Test("Audio tracks in two languages are not mixed into one copy, and nothing is encoded (F942)")
@MainActor
func shrinkRefusesAlternateTracks() async throws {
    let f = try await MixFixture(recordingExtension: "mov", duration: 3, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 3),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 3)],
                                     alternates: true, languages: ["eng", "fra"])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    let original = try Data(contentsOf: f.recording)

    let reason = try await f.reason()
    #expect(reason?.message.contains("in different languages") == true, "\(String(describing: reason))")
    await f.shrink()

    #expect(!encoded.value)
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
}

// Review of F942, R3: ffmpeg puts every audio track of a file in one alternate group (tagged `und`), so the
// group alone told Shrink "alternatives… such as languages" about a call saved one side per track.
@Test("Tracks ffmpeg put in one alternate group, untagged, are mixed into the copy (F942 review R3)")
@MainActor
func shrinkMixesTracksFFmpegGrouped() async throws {
    let f = try await MixFixture(recordingExtension: "mp4", duration: 8, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 8, audibleTo: 4),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 8, audibleFrom: 4)],
                                     alternates: true)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil, "offered: one group with no languages is not two languages")

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    #expect(fixtureToneAmplitude(copy, rate: 16_000, frequency: 800, from: 4.5, to: 7.5) > 0.1, "the disabled track is in the copy")
}

@Test("The confirmation says that several tracks are mixed into one and cannot be separated again (F942)")
@MainActor
func shrinkConfirmationSaysTheTracksAreMixed() async throws {
    let f = try await MixFixture(recordingExtension: "mov", duration: 3, mixing: true) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 3),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 3)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])

    let request = try #require(f.model.pendingShrink, "\(f.model.alertMessage ?? "no alert")")
    let message = AppModel.shrinkConfirmationMessage(request)
    #expect(message.contains("mixed into one"), "\(message)")
    #expect(message.contains("can't be separated"), "\(message)")
}

// MARK: - F980: Shrink of a recording that needs mixing is held back

// The second review of F942 found the audit of a mixed copy still letting Shrink delete an original whose
// sound was not in the copy, with the real mixer: D1, a quiet track whose stereo channels cancel, judged only
// above a tenth of the whole recording's level, even where it sounds alone; D2, one NaN channel of a float
// WAV, which silenced the mix while the audit read NaN as silence. The integrator's decision, following the
// user's answer to F942 ("keep refusing now, mix later"): Shrink refuses every recording that needs mixing
// until F980 proves the audit; transcription keeps mixing, since it deletes nothing. These run the shipped
// behaviour; the tests above run the held-back path.

@Test("Shrink refuses a recording that needs mixing, before anything is mixed or encoded (F942, F980)")
@MainActor
func shrinkRefusesEveryRecordingThatNeedsMixing() async throws {
    let poly = [300.0, 500.0, 700.0, 900.0].map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 4) }
    let surround = [300.0, 500.0, 700.0, 900.0, 1_100.0, 1_300.0].map { fixtureTone(frequency: $0, amplitude: 0.1, seconds: 4) }
    let cases: [(label: String, ext: String, holds: String, write: (URL) async throws -> Void)] = [
        ("two tracks", "mov", "2 audio tracks", { url in
            try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 4),
                                                   FixtureTrack(channels: [(800, 0.2)], seconds: 4)])
        }),
        ("four channels, no layout", "wav", "4 channels", { url in try fixturePolyWAV(poly).write(to: url) }),
        ("5.1", "wav", "6 channels", { url in try fixturePolyWAV(surround, mask: 0x3F).write(to: url) }),
    ]
    for c in cases {
        let f = try await MixFixture(recordingExtension: c.ext, duration: 4, write: c.write)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mixed = CallFlag(), encoded = CallFlag()
        f.model.mixForShrink = { _, _ in mixed.set(); throw CancellationError() }
        f.model.encodeForShrink = { _, _, _ in encoded.set() }
        let original = try Data(contentsOf: f.recording)

        let reason = try await f.reason()
        #expect(reason?.message == "This recording has \(c.holds); shrinking it isn't available yet, so its audio is kept as it is.",
                "\(c.label): \(String(describing: reason))")
        await f.shrink()

        let alert = f.model.alertMessage ?? "nil"
        #expect(alert.contains("isn't available yet"), "\(c.label): \(alert)")
        #expect(!mixed.value && !encoded.value, "\(c.label): nothing is mixed or encoded")
        #expect(try Data(contentsOf: f.recording) == original, "\(c.label)")
        #expect(!f.exists("recording.m4a"), "\(c.label)")
    }
}

@Test("A quiet track whose channels cancel, alone for half the recording, keeps its original (F942 second review D1, F980)")
@MainActor
func shrinkKeepsAnOriginalWithAQuietTrackWhoseChannelsCancel() async throws {
    // The review's N1 at 0.015: track 1 speaks for the first 10 s; track 2 is stereo in opposite polarity,
    // under a tenth of the recording's level, and alone from 10 s. The audit let its loss through.
    let f = try await MixFixture(recordingExtension: "mov", duration: 20) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.5)], seconds: 20, audibleTo: 10),
                                               FixtureTrack(channels: [(800, 0.015), (800, -0.015)], seconds: 20)])
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.mov"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original, "\(alert)")
    #expect(!f.exists("recording.m4a"), "\(alert)")
}

@Test("A float WAV with a NaN channel keeps its original (F942 second review D2, F980)")
@MainActor
func shrinkKeepsAnOriginalWithANaNChannel() async throws {
    // The review's N2: four channels at 16 kHz, the fourth NaN throughout. The mix came out silent and the
    // audit, reading NaN as silence, let a 3.8 MB original go for a 12 KB copy.
    var channels = [300.0, 500.0, 700.0, 900.0].map { fixtureTone(frequency: $0, amplitude: 0.2, seconds: 15, rate: 16_000) }
    channels[3] = [Float](repeating: .nan, count: channels[3].count)
    let f = try await MixFixture(recordingExtension: "wav", duration: 15) { url in
        try fixtureFloatWAV(channels, rate: 16_000).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try Data(contentsOf: f.recording)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(f.exists("recording.wav"), "\(alert)")
    #expect(try Data(contentsOf: f.recording) == original, "\(alert)")
    #expect(!f.exists("recording.m4a"), "\(alert)")
}

@Test("The app's Shrink starts with mixing off, as the plan's switch is (F980)")
@MainActor
func appShrinkStartsWithMixingOff() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F980-switch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    #expect(model.shrinkMixesRecordings == false)
}
