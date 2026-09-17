import Foundation
import Testing
@testable import WhisperCore

// F267 — re-running recovery on a folder that is already indexed.
//
// Recovery is one-shot today: `orphanedRecordings()` excludes any folder whose UUID belongs to a
// meeting (deliberately, so a "recovery" cannot blank a saved title — F148 #1), so the moment a
// partial rebuild is indexed the folder is invisible to the recovery path forever. That property
// is load-bearing in two CLOSED tickets — F256's floor throws rather than index a duration-0
// meeting because such a meeting would be final, and F279's severity argument rests on a stranded
// recording being unrecoverable — and it is true by side effect rather than by decision.

private func makeFolder(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SourceRebuild-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeTrack(_ frames: Int, named name: String, in directory: URL) throws {
    let samples = [Float](repeating: 0.3, count: frames)
    try samples.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(name)) }
}

@Test("A folder whose rebuild was truncated is offered a second attempt")
func truncatedFolderIsOffered() throws {
    let directory = try makeFolder("offered")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    try writeTrack(96_000, named: "microphone-audio.f32", in: directory)
    // A previous, short rebuild is what the index points at.
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: directory.appendingPathComponent("meeting-recovered.wav"))

    let offer = try #require(SourceRebuild.offer(in: directory, currentDuration: 0.1))
    #expect(offer.expectedDurationSeconds == 2.0)
    #expect(offer.currentDurationSeconds == 0.1)
    #expect(offer.wouldSupersedeRecording)
}

@Test("A folder holding a finished meeting.wav is refused, which is F255")
func finishedCaptureIsRefused() throws {
    // The refusal that matters, and the reason this is not merely a filter. `meeting.wav` is
    // written only by `AudioCaptureEngine.stop()`, so its presence means a capture finished
    // normally. Rebuilding over it and repointing the index at `meeting-recovered.wav` is exactly
    // the harm F255 exists to prevent: the complete recording left on disk, referred to by
    // nothing. A user who believes their `meeting.wav` is bad has the manual procedure.
    let directory = try makeFolder("finished")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 96_000), sampleRate: 48_000)
        .write(to: directory.appendingPathComponent("meeting.wav"))

    #expect(SourceRebuild.offer(in: directory, currentDuration: 2.0) == nil)
}

@Test("A folder with no source tracks left is not offered")
func noTracksMeansNoOffer() throws {
    let directory = try makeFolder("notracks")
    defer { try? FileManager.default.removeItem(at: directory) }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: directory.appendingPathComponent("meeting-recovered.wav"))

    #expect(SourceRebuild.offer(in: directory, currentDuration: 0.1) == nil)
}

@Test("A meeting whose audio file vanished is still offered")
func missingRecordingIsStillOffered() throws {
    // The case with the most to gain: the index points at a file that is gone, and the tracks
    // that could reproduce it are right there.
    let directory = try makeFolder("missing")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(48_000, named: "system-audio.f32", in: directory)

    let offer = try #require(SourceRebuild.offer(in: directory, currentDuration: 0))
    #expect(offer.expectedDurationSeconds == 1.0)
    #expect(!offer.wouldSupersedeRecording)
}

@Test("Rebuilding keeps the superseded audio, byte for byte")
func rebuildPreservesTheOldRecording() throws {
    // "Never delete audio" has to cover overwriting. The rebuild writes a fixed filename, so a
    // second run would destroy the first — deleting audio, with the filename hiding it.
    let directory = try makeFolder("preserve")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    try writeTrack(96_000, named: "microphone-audio.f32", in: directory)
    let previous = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
    try previous.write(to: directory.appendingPathComponent("meeting-recovered.wav"))

    let offer = try #require(SourceRebuild.offer(in: directory, currentDuration: 0.1))
    let rebuilt = try #require(try SourceRebuild.rebuild(offer))

    // The new rebuild took the original name, so the meeting's `recordingPath` stays valid.
    #expect(rebuilt.recordingURL.lastPathComponent == "meeting-recovered.wav")
    #expect(abs(rebuilt.duration - 2.0) < 0.001)
    // And the old one is still here, unchanged.
    let superseded = directory.appendingPathComponent("meeting-recovered-superseded-1.wav")
    #expect(try Data(contentsOf: superseded) == previous)
}

@Test("A third rebuild does not overwrite the second's superseded copy")
func supersededNamesDoNotCollide() throws {
    let directory = try makeFolder("collide")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    let first = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
    try first.write(to: directory.appendingPathComponent("meeting-recovered.wav"))

    let offerA = try #require(SourceRebuild.offer(in: directory, currentDuration: 0.1))
    _ = try SourceRebuild.rebuild(offerA)
    let offerB = try #require(SourceRebuild.offer(in: directory, currentDuration: 2.0))
    _ = try SourceRebuild.rebuild(offerB)

    #expect(try Data(contentsOf: directory.appendingPathComponent("meeting-recovered-superseded-1.wav")) == first)
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("meeting-recovered-superseded-2.wav").path
    ))
}

@Test("A rebuild that fails leaves the previous recording in place")
func failedRebuildRestoresThePreviousRecording() throws {
    // The move-aside happens before the rebuild, so a rebuild that throws must not leave the
    // meeting pointing at nothing. Losing the old audio to a failed attempt at a better one is
    // worse than the truncation being fixed.
    let directory = try makeFolder("failed")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    let previous = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
    try previous.write(to: directory.appendingPathComponent("meeting-recovered.wav"))

    let offer = try #require(SourceRebuild.offer(in: directory, currentDuration: 0.1))
    #expect(throws: (any Error).self) {
        _ = try SourceRebuild.rebuild(offer, openTrack: { _ in { _ in throw CocoaError(.fileReadUnknown) } })
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("meeting-recovered.wav")) == previous)
}

@Test("The manifest names the file the old audio moved to")
func manifestRecordsTheSupersededRecording() throws {
    // Otherwise "never delete audio" is honoured by a file nothing refers to, which is an orphan
    // — the shape of defect F255 was about. The rebuild path would not mention it on its own:
    // `writeRecoveryManifestIfNeeded` writes only when no manifest exists, and a folder reaching
    // F267 has been recovered already.
    let directory = try makeFolder("manifest")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(96_000, named: "system-audio.f32", in: directory)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: directory.appendingPathComponent("meeting-recovered.wav"))
    // The manifest a previous recovery left behind.
    _ = try InterruptedRecordingRecovery.recover(in: directory)

    let offerA = try #require(SourceRebuild.offer(in: directory, currentDuration: 0.1))
    _ = try SourceRebuild.rebuild(offerA)
    let offerB = try #require(SourceRebuild.offer(in: directory, currentDuration: 2.0))
    _ = try SourceRebuild.rebuild(offerB)

    let manifestURL = ["source-tracks.json", "source-tracks.recovered.json"]
        .map(directory.appendingPathComponent)
        .first { FileManager.default.fileExists(atPath: $0.path) }
    let data = try Data(contentsOf: try #require(manifestURL))
    let manifest = try JSONDecoder().decode(SourceTrackManifest.self, from: data)

    // Oldest first, and the rebuild count falls out of the list rather than needing its own field.
    #expect(manifest.supersededRecordings == [
        "meeting-recovered-superseded-1.wav",
        "meeting-recovered-superseded-2.wav",
    ])
    // Every file it names is actually there.
    for name in manifest.supersededRecordings {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
}

@Test("A folder rebuilt once keeps the key out of its manifest entirely")
func unrebuiltManifestOmitsTheKey() throws {
    let directory = try makeFolder("nokey")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeTrack(48_000, named: "system-audio.f32", in: directory)
    _ = try InterruptedRecordingRecovery.recover(in: directory)

    let json = try String(
        contentsOf: directory.appendingPathComponent("source-tracks.recovered.json"),
        encoding: .utf8
    )
    #expect(!json.contains("supersededRecordings"))
}
