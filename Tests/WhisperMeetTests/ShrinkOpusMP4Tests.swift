import AVFoundation
import Foundation
import ObjCExceptionBridge
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1037 — an MP4 holding Opus beside the recording crashed the app when Shrink was pressed (review 1 of Wave 8 lane A,
// finding 2). AVAudioFile opens such a file, reports its length as 0 frames and its packets as 0 frames each, and
// `framePosition` then *raises* (`com.apple.coreaudio.avfaudio`, 'prm?', from `CheckClientFormatSet`) — an Objective-C
// exception no Swift `catch` sees — inside `DecodedAudio.fullyDecoded`'s loop; `read(into:)` on the same file throws
// the same error as a Swift error. Measured on macOS 27 with ffmpeg 8.1.2's Opus in MP4, mono and stereo.
// And it declared 0 seconds, which F911's length check took as a download holding nothing.
//
// The fixture is 2 s of a tone per channel, Opus in MP4, made with ffmpeg 8.1.2 (committed: CI has no ffmpeg).

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/opus-in-mp4-stereo-2s.mp4")

@Test("Decoding an MP4 holding Opus raises nothing, and reads it whole through the reader that can (F1037)")
func opusInMP4DecodesWithoutRaising() async throws {
    // Through the bridge, so the unfixed raise is a failed expectation here rather than this test process's abort.
    var outcome: Result<DecodedAudio.Decoded, Error>?
    var exception: NSError?
    let completed = WMRunCatchingObjCExceptions({
        outcome = Result { try DecodedAudio.fullyDecoded(of: fixture) }
    }, &exception)
    #expect(completed, "AVAudioFile raised: \(exception?.localizedDescription ?? "?")")
    if case .success? = outcome { Issue.record("AVAudioFile cannot read this file; fullyDecoded must not claim it did") }

    let decoded = try await DecodedAudio.fullyDecodedEveryTrack(of: fixture)
    #expect(decoded.channelWindowLevels.count == 2)
    #expect(abs(decoded.duration - 2) < 0.05, "\(decoded.duration)")
    #expect(decoded.level > 0.05, "\(decoded.level)")
}

@Test("An MP4 holding Opus declares no length, rather than 0 seconds (F1037)")
func opusInMP4DeclaresNoLength() {
    #expect(DecodedAudio.declaredDuration(of: fixture) == nil)
}

/// A link import's folder: the Opus MP4 download beside a mono WAV of `seconds` from its decode, indexed against the WAV.
@MainActor
private func opusFixture(wavSeconds: Double) async throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1037-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("recording.mp4"))
    // What ffmpeg's `-ac 1` makes of it: the channels' mean, decoded by the reader that reads it.
    let asset = AVURLAsset(url: fixture)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
    reader.add(output)
    try #require(reader.startReading())
    var mono: [Float] = []
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
        let frames = CMSampleBufferGetNumSamples(buffer)
        var samples = [Float](repeating: 0, count: frames * 2)
        _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        for n in 0..<frames { mono.append((samples[2 * n] + samples[2 * n + 1]) / 2) }
    }
    try WAVWriter.wavData(from: Array(mono.prefix(Int(wavSeconds * 48_000))), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("recording.wav"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(
        id: id, title: "Conference talk", duration: wavSeconds,
        recordingPath: "Recordings/\(id.uuidString)/recording.wav", status: .completed, transcriptText: "Hi.",
        recoverySource: RecoveredRecording.Source.importedRecording.rawValue))
    model.availableBytesForShrink = { _ in .max }
    return (root, model, id, folder)
}

@Test("Shrink beside an MP4 holding Opus checks its channels and removes it, and does not crash (F1037)")
@MainActor
func shrinkBesideAnOpusMP4DoesNotCrash() async throws {
    let f = try await opusFixture(wavSeconds: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    // ffprobe's answer for it (F962), which a test stubs: 2 s.
    f.model.measureDownloadForShrink = { _ in 2 }

    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])
    await f.model.performShrink(confirmed: true)?.value

    let alert = f.model.alertMessage ?? "nil"
    #expect(alert.contains("Shrunk"), "a tone per channel: \(alert)")
    #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("recording.mp4").path), "\(alert)")
}

@Test("An MP4 holding Opus beside a shorter recording is kept: its 0 s is not a length (F1037)")
@MainActor
func shrinkKeepsAnOpusMP4BesideAShorterRecording() async throws {
    let f = try await opusFixture(wavSeconds: 1)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try Data(contentsOf: f.folder.appendingPathComponent("recording.mp4"))

    await f.model.refreshStorage(ids: [f.id])
    f.model.requestShrink(ids: [f.id])
    await f.model.performShrink(confirmed: true)?.value

    let alert = f.model.alertMessage ?? "nil"
    #expect((try? Data(contentsOf: f.folder.appendingPathComponent("recording.mp4"))) == before, "\(alert)")
    #expect(alert.contains("recording.mp4"), "\(alert)")
}
