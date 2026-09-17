import Foundation
import Testing
@testable import WhisperCore

// F280 — `frameCount(at:)` used `try?` on `attributesOfItem`, so a stat failure returned 0. The
// consequences cascade quietly: `recover` then passes `url: nil` for that track, `RawFloatReader`
// returns zero-filled samples for every chunk, and the whole channel becomes silence — with no
// truncation reported, because no read ever failed.
//
// That is the same conflation **F256** fixed one level down, left in place one level up, and after
// F256 it is the *only* remaining way to get a silently silent channel out of a rebuild. Narrow
// (a file that opens will usually stat; the reachable cases are a racing unlink, a disappearing
// volume, or EMFILE) but the outcome is precisely the one F256 exists to prevent.
//
// The distinction that has to survive: **absent** is legitimate and must stay 0 — a track that was
// never written is what `RawFloatReader(url: nil)` is for, and a microphone-only or system-only
// recording is an ordinary thing. **Present but unstattable** is an error.

/// A size lookup that fails for one named file and behaves normally for everything else.
private func statFailing(for failingName: String) -> InterruptedRecordingRecovery.SizeLookup {
    { url in
        if url.lastPathComponent == failingName {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        }
        return try InterruptedRecordingRecovery.fileSizeLookup(url)
    }
}

private func makeTrackDirectory(
    systemFrames: Int,
    microphoneFrames: Int
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F280-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ count: Int, to name: String) throws {
        var data = Data(capacity: count * 4)
        for index in 0..<count {
            var bits = Float(index % 7) .bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: directory.appendingPathComponent(name))
    }
    try write(systemFrames, to: "system-audio.f32")
    try write(microphoneFrames, to: "microphone-audio.f32")
    return directory
}

@Test("A track that cannot be stat'd is an error, not a silent channel (F280)")
func unstattableTrackIsReported() throws {
    let directory = try makeTrackDirectory(systemFrames: 400, microphoneFrames: 400)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: (any Error).self) {
        _ = try InterruptedRecordingRecovery.recover(
            in: directory,
            sampleRate: 48_000,
            openTrack: InterruptedRecordingRecovery.fileTrackOpener,
            sizeOf: statFailing(for: "microphone-audio.f32")
        )
    }
}

@Test("A failed stat leaves the folder untouched, so recovery can be retried (F280)")
func aFailedStatWritesNothing() throws {
    // The F256 contract: an error that means "this rebuild cannot be trusted" must not leave a
    // half-built `meeting-recovered.wav` behind, because the next launch would find it and treat
    // the truncated result as the recording.
    let directory = try makeTrackDirectory(systemFrames: 400, microphoneFrames: 400)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try? InterruptedRecordingRecovery.recover(
        in: directory,
        sampleRate: 48_000,
        openTrack: InterruptedRecordingRecovery.fileTrackOpener,
        sizeOf: statFailing(for: "system-audio.f32")
    )

    let rebuilt = directory.appendingPathComponent("meeting-recovered.wav")
    #expect(!FileManager.default.fileExists(atPath: rebuilt.path),
            "left a rebuild behind that the next launch would trust")
}

@Test("An absent track is still legitimately zero frames (F280)")
func absentTrackStaysZero() throws {
    // The distinction the fix turns on. A system-audio-only or microphone-only recording is
    // ordinary — the missing side must NOT become an error, or every such recovery breaks.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F280-absent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var data = Data(capacity: 240 * 4)
    for _ in 0..<240 {
        var bits = Float(0.5).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    try data.write(to: directory.appendingPathComponent("system-audio.f32"))
    // No microphone file at all.

    let recovered = try InterruptedRecordingRecovery.recover(in: directory, sampleRate: 48_000)
    let rebuilt = try #require(recovered)
    #expect(rebuilt.duration > 0)
    #expect(abs(rebuilt.duration - 240.0 / 48_000.0) < 0.000_1)
}

@Test("The default size lookup reports a real file's size and rejects a missing one (F280)")
func defaultLookupBehaviour() throws {
    let directory = try makeTrackDirectory(systemFrames: 100, microphoneFrames: 0)
    defer { try? FileManager.default.removeItem(at: directory) }

    let size = try InterruptedRecordingRecovery.fileSizeLookup(
        directory.appendingPathComponent("system-audio.f32")
    )
    #expect(size == 400)

    // Missing is distinguishable from unstattable: the lookup reports nil rather than throwing,
    // because "never written" is not a failure.
    #expect(try InterruptedRecordingRecovery.fileSizeLookup(
        directory.appendingPathComponent("nothing-here.f32")
    ) == nil)
}
