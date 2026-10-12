import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F942, F953 — Shrink keeps one mono track. Since F801 it refused an import with several audio tracks,
// or with more than two channels, because its encode kept track 1 (or channel 1) and the rest would
// have been deleted with the original; F953 noted that this also refused positioned 5.1 audio. The
// user's decision (2026-10-12): mix every track into one, for transcription and for Shrink. So Shrink
// now mixes every channel of every track into its copy and checks the copy against each of them, and
// refuses only what it cannot mix: alternate tracks (languages) and files it cannot read. Driven
// through the calls the Shrink button makes, with the real mixer, encoder and decoder.

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

    init(recordingExtension ext: String, duration: TimeInterval, write: (URL) async throws -> Void) async throws {
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
    let f = try await MixFixture(recordingExtension: "mov", duration: 8) { url in
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
    let f = try await MixFixture(recordingExtension: "wav", duration: 6) { url in
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
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone) - 0.19) < 0.015, "\(tone) Hz")
    }
}

@Test("A positioned 5.1 WAV is shrunk with all six channels in the copy, its LFE too (F953)")
@MainActor
func shrinkMixesAFivePointOneImport() async throws {
    let tones = [300.0, 500.0, 700.0, 900.0, 1_100.0, 1_300.0]
    let f = try await MixFixture(recordingExtension: "wav", duration: 6) { url in
        try fixturePolyWAV(tones.map { fixtureTone(frequency: $0, amplitude: 0.1, seconds: 6) }, mask: 0x3F).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.reason() == nil)

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    for tone in tones {
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone) - 0.095) < 0.01, "\(tone) Hz")
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

@Test("A mix that lost a channel is caught where that channel speaks, and the original is kept (F942)")
@MainActor
func shrinkRefusesAMixThatLostAChannel() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: 20) { url in
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
    #expect(alert.contains("is missing sound the recording has at about 0:05"), "speaker 2 starts at 0:05: \(alert)")
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
    #expect(try f.hiddenTemps().isEmpty, "the mix and the encode's temps are removed")
}

@Test("The same panel through the real mixer is shrunk with every speaker in the copy (F942 control)")
@MainActor
func shrinkMixesAPanelWhoseMicrophonesTakeTurns() async throws {
    let f = try await MixFixture(recordingExtension: "wav", duration: 20) { url in
        try fixturePolyWAV(panelChannels()).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }

    await f.shrink()

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "\(alert)")
    let copy = try f.copy()
    for (speaker, tone) in [300.0, 500.0, 700.0, 900.0].enumerated() {
        let from = Double(speaker) * 5 + 0.5
        // The voice and its bleed into the other three microphones, summed: 0.2 × (1 + 3 × 0.178) × 0.95.
        #expect(abs(fixtureToneAmplitude(copy, rate: 16_000, frequency: tone, from: from, to: from + 4) - 0.291) < 0.02,
                "speaker \(speaker + 1)")
    }
}

@Test("Alternate audio tracks, such as two languages, are not mixed into one copy, and nothing is encoded (F942)")
@MainActor
func shrinkRefusesAlternateTracks() async throws {
    let f = try await MixFixture(recordingExtension: "mov", duration: 3) { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 3),
                                               FixtureTrack(channels: [(800, 0.2)], seconds: 3)], alternates: true)
    }
    defer { try? FileManager.default.removeItem(at: f.root) }
    let encoded = CallFlag()
    f.model.encodeForShrink = { _, _, _ in encoded.set() }
    let original = try Data(contentsOf: f.recording)

    let reason = try await f.reason()
    #expect(reason?.message.contains("alternatives") == true, "\(String(describing: reason))")
    await f.shrink()

    #expect(!encoded.value)
    #expect(try Data(contentsOf: f.recording) == original)
    #expect(!f.exists("recording.m4a"))
}

@Test("The confirmation says that several tracks are mixed into one and cannot be separated again (F942)")
@MainActor
func shrinkConfirmationSaysTheTracksAreMixed() async throws {
    let f = try await MixFixture(recordingExtension: "mov", duration: 3) { url in
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
