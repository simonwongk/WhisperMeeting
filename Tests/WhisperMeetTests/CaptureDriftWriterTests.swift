import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F556 — the capture path's own call. `CaptureClockDriftTests` drives `FloatTrackFile.appendCaptured`
// over half an hour of synthetic timestamps; these check that `FloatTrackWriter.append`, which the
// SCStream sample handler calls for every buffer, goes through it with the buffer's real
// presentation time. Two hand-built `CMSampleBuffer`s each (F856's fixture): the second 300 frames
// (6.25 ms) late or early against the first, inside the band F151's 10 ms tolerance used to ignore.

private func writer() throws -> (FloatTrackWriter, URL) {
    let url = try CapturedSampleBuffer.temporaryTrackURL("F556")
    return (try FloatTrackWriter(outputURL: url, targetSampleRate: CapturedSampleBuffer.rate, deviceSync: { _ in }), url)
}

@Test("A buffer 300 frames late gets its first frame written twice, not left 6 ms behind (F556)")
func aLateBufferIsSteeredBack() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024))
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024, startFrame: 1_024 + 300))
    let track = try writer.finish()

    #expect(track.frameCount == 2_049, "the late buffer was written where the frames ran out, not where its time says")
    let recorded = try CapturedSampleBuffer.samples(of: track)
    try #require(recorded.count == 2_049)
    #expect(recorded[1_024] == recorded[1_025], "the repeated frame is the late buffer's own first sample")
    #expect(writer.droppedFrames == 0, "a drift correction is not a dropped-buffer gap")
}

@Test("A buffer 300 frames early has its first frame left out (F556)")
func anEarlyBufferIsSteeredBack() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024))
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024, startFrame: 1_024 - 300))
    let track = try writer.finish()

    #expect(track.frameCount == 2_047)
    #expect(writer.droppedFrames == 0)
}

@Test("A buffer a whole second late is still padded with that second of silence (F556 keeps F151)")
func aDroppedSecondIsStillPadded() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024))
    _ = try writer.append(CapturedSampleBuffer.make(channels: 1, frames: 1_024, startFrame: 1_024 + 48_000))
    let track = try writer.finish()

    #expect(track.frameCount == 2_048 + 48_000)
    #expect(writer.droppedFrames == 48_000)
}
