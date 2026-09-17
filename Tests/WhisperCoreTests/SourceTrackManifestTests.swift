import Foundation
import Testing
@testable import WhisperCore

// F282 — F275 pads a gap the capture could not record with silence, so that `sample offset ==
// elapsed time` stays true. But `source-tracks.json` said nothing about it: a padded recording was
// byte-indistinguishable from one that was never interrupted.
//
// **The emphasis in the filed ticket was wrong and this is the correction.** I filed it as "the
// manifest should carry the right alignment string", and whisper-62's F281 rule settles the
// question better: never assert something untrue about the recording, and a document that reads as
// complete because nothing contradicts it is making that false claim *by omission*. An alignment
// value saying "padded" tells a consumer that something was inserted; it does not tell them WHERE,
// so they still cannot skip those spans and would count inserted silence as recorded non-speech —
// which matters most to the forced aligner and to anything deriving speaker statistics. So the gap
// LIST is the feature and the alignment value is the label.
//
// It was also `private` inside `AudioCaptureEngine.swift`, which is why it could drift from what it
// described without anything noticing. Moved to `WhisperCore` for the same reason F278 moved the
// mixer: a manifest nothing can test is a claim nobody checks.

private func decodeManifest(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func temporaryManifestURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("F282-\(UUID().uuidString).json")
}

private let plainTracks = (
    system: FloatTrack(url: URL(fileURLWithPath: "/tmp/s.f32"), firstPresentationTime: 100, frameCount: 48_000),
    microphone: FloatTrack(url: URL(fileURLWithPath: "/tmp/m.f32"), firstPresentationTime: 100, frameCount: 48_000)
)

@Test("An uninterrupted capture declares the captured timeline and no gaps (F282)")
func uninterruptedCaptureDeclaresItsTimeline() throws {
    let url = temporaryManifestURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try SourceTrackManifest.write(
        system: plainTracks.system,
        microphone: plainTracks.microphone,
        sampleRate: 48_000,
        paddedGaps: [],
        to: url
    )

    let object = try decodeManifest(at: url)
    #expect(object["recoveryAlignment"] as? String == "captured-timeline")
    // Absent, not an empty array: a recording with no gaps should not carry a field implying the
    // question came up. `source-tracks.json` is read by `AppModel.sourceTracks`, which takes only
    // `file` and `frameCount`, so additive fields are safe — but a field present on every recording
    // stops being a signal.
    #expect(object["paddedGaps"] == nil)
}

@Test("A padded capture records where each gap is, not merely that one exists (F282)")
func paddedCaptureRecordsTheGapPositions() throws {
    let url = temporaryManifestURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try SourceTrackManifest.write(
        system: plainTracks.system,
        microphone: plainTracks.microphone,
        sampleRate: 48_000,
        paddedGaps: [
            SourceTrackManifest.PaddedGap(startSeconds: 12.5, durationSeconds: 45),
            SourceTrackManifest.PaddedGap(startSeconds: 300, durationSeconds: 8),
        ],
        to: url
    )

    let object = try decodeManifest(at: url)
    #expect(object["recoveryAlignment"] as? String == "padded-after-restart")
    let gaps = try #require(object["paddedGaps"] as? [[String: Any]])
    #expect(gaps.count == 2)
    #expect(gaps[0]["startSeconds"] as? Double == 12.5)
    #expect(gaps[0]["durationSeconds"] as? Double == 45)
    #expect(gaps[1]["startSeconds"] as? Double == 300)
}

@Test("The alignment value matches what the restart policy calls it (F282)")
func alignmentValueMatchesThePolicy() {
    // Two strings in two files describing one state is how they start to disagree. The policy owns
    // the vocabulary because it owns the decision.
    #expect(SourceTrackManifest.paddedAlignment == CaptureRestartPolicy.paddedAlignment)
    #expect(SourceTrackManifest.capturedAlignment == "captured-timeline")
}

@Test("A manifest round-trips its gaps, so a reader gets them back (F282)")
func manifestRoundTripsItsGaps() throws {
    let url = temporaryManifestURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let gaps = [SourceTrackManifest.PaddedGap(startSeconds: 1, durationSeconds: 2)]

    try SourceTrackManifest.write(
        system: plainTracks.system,
        microphone: plainTracks.microphone,
        sampleRate: 48_000,
        paddedGaps: gaps,
        to: url
    )
    let decoded = try JSONDecoder().decode(
        SourceTrackManifest.self,
        from: try Data(contentsOf: url)
    )

    #expect(decoded.paddedGaps == gaps)
    #expect(decoded.recoveryAlignment == SourceTrackManifest.paddedAlignment)
    #expect(decoded.systemAudio.frameCount == 48_000)
}

@Test("A manifest written before F282 still decodes, with no gaps (F282)")
func olderManifestsStillDecode() throws {
    // Every recording already on this Mac has a manifest without these two fields. They must decode
    // to "no gaps, captured timeline" rather than failing — the same lenient-optional rule F188 set
    // and F250 applied to the index an hour ago.
    let json = #"""
    {"systemAudio":{"file":"system-audio.f32","format":"float32-little-endian",
      "sampleRate":48000,"channels":1,"frameCount":100,"startOffsetSeconds":0},
     "microphoneAudio":{"file":"microphone-audio.f32","format":"float32-little-endian",
      "sampleRate":48000,"channels":1,"frameCount":100,"startOffsetSeconds":0}}
    """#
    let decoded = try JSONDecoder().decode(SourceTrackManifest.self, from: Data(json.utf8))
    #expect(decoded.paddedGaps.isEmpty)
    #expect(decoded.recoveryAlignment == SourceTrackManifest.capturedAlignment)
}

@Test("Two tracks that never received a buffer are still an error (F282)")
func noPresentationTimeStillThrows() {
    let url = temporaryManifestURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: (any Error).self) {
        try SourceTrackManifest.write(
            system: FloatTrack(url: plainTracks.system.url, firstPresentationTime: nil, frameCount: 0),
            microphone: FloatTrack(url: plainTracks.microphone.url, firstPresentationTime: nil, frameCount: 0),
            sampleRate: 48_000,
            paddedGaps: [],
            to: url
        )
    }
}

// MARK: - F282: a rebuild must not erase the padding the capture recorded

@Test("A rebuild of a padded capture reports the gaps, not just its own alignment (F282)")
func rebuildPreservesPaddingFromTheSidecar() throws {
    // The case the ticket's second half is about. A capture that was padded and THEN interrupted
    // never reached `stop()`, so `source-tracks.json` was never written — the padding survives only
    // in the session sidecar. Recovery then writes `source-tracks.recovered.json` describing its own
    // zero-aligned rebuild, and without this the inserted silence is invisible in every manifest
    // the folder has.
    //
    // Both facts are true of such a file, and the rebuild's own alignment is the less specific of
    // the two: "zero-aligned-after-interruption" says how the tracks were joined, while the gaps say
    // which spans are not audio at all.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F282-rebuild-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var samples = Data(capacity: 480 * 4)
    for _ in 0..<480 {
        var bits = Float(0.4).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { samples.append(contentsOf: $0) }
    }
    try samples.write(to: directory.appendingPathComponent("system-audio.f32"))
    try Data().write(to: directory.appendingPathComponent("microphone-audio.f32"))

    var session = RecordingSession(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_757_000_000),
        title: "",
        markers: []
    )
    session.paddedGaps = [
        RecordingSession.PaddedGap(
            seconds: 30,
            resumedAt: Date(timeIntervalSince1970: 1_757_000_100)
        )
    ]
    try RecordingSessionSidecar.write(session, in: directory)

    _ = try InterruptedRecordingRecovery.recover(in: directory, sampleRate: 48_000)

    let manifest = try JSONDecoder().decode(
        SourceTrackManifest.self,
        from: try Data(contentsOf: directory.appendingPathComponent("source-tracks.recovered.json"))
    )
    #expect(manifest.paddedGaps.count == 1)
    #expect(manifest.paddedGaps.first?.durationSeconds == 30)
    #expect(manifest.recoveryAlignment == "zero-aligned-after-interruption-with-padding")
}

@Test("A rebuild with no padding keeps its plain alignment (F282)")
func rebuildWithoutPaddingIsUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F282-plain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var samples = Data(capacity: 240 * 4)
    for _ in 0..<240 {
        var bits = Float(0.4).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { samples.append(contentsOf: $0) }
    }
    try samples.write(to: directory.appendingPathComponent("system-audio.f32"))
    try Data().write(to: directory.appendingPathComponent("microphone-audio.f32"))

    _ = try InterruptedRecordingRecovery.recover(in: directory, sampleRate: 48_000)

    let manifest = try JSONDecoder().decode(
        SourceTrackManifest.self,
        from: try Data(contentsOf: directory.appendingPathComponent("source-tracks.recovered.json"))
    )
    #expect(manifest.paddedGaps.isEmpty)
    #expect(manifest.recoveryAlignment == "zero-aligned-after-interruption")
}
