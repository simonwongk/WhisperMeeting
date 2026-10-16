import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F660 — after F581 the re-run's slice decoder reads any WAV layout AVFoundation can, but an import
// kept in its own container (.m4a, .mp3, .aiff, .caf) was refused before it got there: "This recording
// isn't a native WAV". AVAudioFile decodes those too. A one-track import is now decoded, span only, by
// the same `decodedSegmentClip`; the recording is only read. An import with several audio tracks is
// still refused: AVAudioFile reads the first track only, where the meeting's own transcription heard
// every track mixed (F942), so a re-run clip would be other audio than the line was transcribed from.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class HeardClip: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (rate: Double, channels: [[Float]])?
    var clip: (rate: Double, channels: [[Float]])? { lock.withLock { value } }
    func set(_ clip: (rate: Double, channels: [[Float]])) { lock.withLock { value = clip } }
}

/// A model holding one completed meeting whose recording is `fileName` in its folder, written by `write`,
/// with lines at 0–2 s and 2–3 s.
@MainActor
private func meeting(recording fileName: String, write: (URL) async throws -> Void) async throws -> (AppModel, UUID, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F660-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let recording = dir.appendingPathComponent(fileName)
    try await write(recording)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let lines = [seg("first", 0, 2), seg("second wrong", 2, 3)]
    model.store.upsert(MeetingRecord(
        id: id, title: "Import", recordingPath: "Recordings/\(id.uuidString)/\(fileName)",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    return (model, id, root, recording)
}

/// Runs a re-run of line 1 with a stub engine that decodes the clip it is handed.
@MainActor
private func reRunSecondLine(_ model: AppModel, _ id: UUID) async -> HeardClip {
    let heard = HeardClip()
    model.runTranscriptionEngineOverride = { _, clipURL in
        if let decoded = try? fixtureDecode(clipURL) { heard.set(decoded) }
        return TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                                   confidence: nil, segments: [seg("second right", 0, 1)])
    }
    await model.reTranscribeSegment(id: id, index: 1)
    return heard
}

@MainActor
@Test("A segment re-run of a one-track .m4a import decodes just that line's audio and splices the result (F660)")
func segmentReRunOfAnM4AImportDecodesTheLine() async throws {
    // One AAC track: 300 Hz for the first line's two seconds, then 700 Hz — the second line's.
    let (model, id, root, recording) = try await meeting(recording: "meeting.m4a") { url in
        let audio = fixtureTone(frequency: 300, amplitude: 0.2, seconds: 2) + fixtureTone(frequency: 700, amplitude: 0.2, seconds: 2)
        try await writeFixtureRawTracks(to: url, [[audio]])
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Data(contentsOf: recording)

    let heard = await reRunSecondLine(model, id)

    #expect(model.alertMessage == nil, "refused: \(model.alertMessage ?? "")")
    let clip = try #require(heard.clip, "no engine ran on a clip")
    let samples = try #require(clip.channels.first)
    #expect(clip.channels.count == 1, "the clip is not mono")
    #expect(abs(Double(samples.count) / clip.rate - 1) < 0.05, "the clip is \(Double(samples.count) / clip.rate) s, not the line's 1 s")
    // AAC is lossy, so the level is checked loosely; the first line's tone must be absent.
    #expect(fixtureToneAmplitude(samples, rate: clip.rate, frequency: 700, from: 0.1, to: 0.9) > 0.15,
            "the second line's tone is not in its clip")
    #expect(fixtureToneAmplitude(samples, rate: clip.rate, frequency: 300, from: 0.1, to: 0.9) < 0.02,
            "the clip carries the first line's audio")
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == ["first", "second right"])
    #expect(try Data(contentsOf: recording) == before, "the recording was modified")
}

@MainActor
@Test("A segment re-run of a .caf import hears the line's tone at its level (F660)")
func segmentReRunOfACAFImportHearsTheLine() async throws {
    let (model, id, root, recording) = try await meeting(recording: "memo.caf") { url in
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let tone = fixtureTone(frequency: 300, amplitude: 0.2, seconds: 2) + fixtureTone(frequency: 700, amplitude: 0.2, seconds: 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.count)))
        buffer.frameLength = AVAudioFrameCount(tone.count)
        tone.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: tone.count) }
        try file.write(from: buffer)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Data(contentsOf: recording)

    let heard = await reRunSecondLine(model, id)

    #expect(model.alertMessage == nil, "refused: \(model.alertMessage ?? "")")
    let clip = try #require(heard.clip, "no engine ran on a clip")
    let samples = try #require(clip.channels.first)
    #expect(abs(fixtureToneAmplitude(samples, rate: clip.rate, frequency: 700, from: 0.1, to: 0.9) - 0.2) < 0.02,
            "the second line's tone is not in its clip at its level")
    #expect(fixtureToneAmplitude(samples, rate: clip.rate, frequency: 300, from: 0.1, to: 0.9) < 0.02)
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == ["first", "second right"])
    #expect(try Data(contentsOf: recording) == before, "the recording was modified")
}

@MainActor
@Test("A segment re-run of an import with several audio tracks is still refused, and says why (F660)")
func segmentReRunOfASeveralTrackImportIsRefused() async throws {
    let (model, id, root, _) = try await meeting(recording: "call.m4a") { url in
        try await writeFixtureTracks(to: url, [FixtureTrack(channels: [(300, 0.2)], seconds: 3),
                                               FixtureTrack(channels: [(700, 0.2)], seconds: 3)])
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let heard = await reRunSecondLine(model, id)

    #expect(heard.clip == nil, "an engine ran on one track of a several-track recording")
    #expect(model.alertMessage == SegmentReRunError.severalAudioTracks.errorDescription)
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == ["first", "second wrong"])
}
