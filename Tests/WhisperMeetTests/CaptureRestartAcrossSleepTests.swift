import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1050 — the review of Wave 8 lane Q (finding 1), read from the code: a wake's restart pads the sleep
// it measured by the wall clock (`AppModel.observeSystemSleep`), while `FloatTrackWriter.append`
// measures every buffer against the track's FIRST timestamp, which no restart moves. If
// ScreenCaptureKit stamps buffers on the host clock — which by Apple's account of
// `mach_absolute_time` does not run while the Mac sleeps — then after waking every buffer looked early
// by the sleep's length, and an early buffer is neither padded (F151) nor steered (F556): both off for
// the rest of the meeting.
//
// The writer now re-anchors at the first buffer after a restart's silence when that buffer is early by
// more than F151's tolerance and by no more than the silence just written. A LATE first buffer keeps
// F460's top-up, which is what a clock that did run through the gap gives — so the fix holds whichever
// clock the stream's stamps turn out to use, which a live recording is still to confirm (F737's check).
// Driven through `FloatTrackWriter.appendSilence`, the restart's own call
// (`AudioCaptureEngine.applyPendingRestartPaddingIfNeeded`), and `append`, the sample handler's.

private func writer() throws -> (FloatTrackWriter, URL) {
    let url = try CapturedSampleBuffer.temporaryTrackURL("F1050")
    return (try FloatTrackWriter(outputURL: url, targetSampleRate: CapturedSampleBuffer.rate, deviceSync: { _ in }), url)
}

private func buffer(at startFrame: Int) throws -> CMSampleBuffer {
    try CapturedSampleBuffer.make(channels: 1, frames: 1_024, startFrame: startFrame)
}

@Test("After a restart across a sleep, a dropped second is still padded and a drifting clock still steered (F1050)")
func paddingAndSteeringSurviveASleep() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var host = 0
    for _ in 0..<10 {
        _ = try writer.append(buffer(at: host))
        host += 1_024
    }
    // The wake pads the two minutes the wall clock says the Mac slept.
    try writer.appendSilence(frames: 48_000 * 120)
    // The host clock stood still meanwhile, so the new stream's stamps carry on from the old one's.
    for _ in 0..<10 {
        _ = try writer.append(buffer(at: host))
        host += 1_024
    }
    #expect(writer.droppedFrames == 0, "the sleep's own silence is the restart's, not a dropped buffer")
    // Then the stream drops a second.
    host += 48_000
    _ = try writer.append(buffer(at: host))
    host += 1_024
    #expect(writer.droppedFrames == 48_000, "a dropped second after the wake was packed in early")
    // And a buffer arrives 300 frames late, as a slow device clock makes it.
    _ = try writer.append(buffer(at: host + 300))
    #expect(writer.driftRepeatedFrames == 1, "drift after the wake was left to run")
    let track = try writer.finish()
    #expect(track.frameCount == 22 * 1_024 + 48_000 * 120 + 48_000 + 1)
}

@Test("A first buffer after a restart that is LATE is topped up as before, so a clock that ran through the gap still pads it whole (F1050 keeps F460)")
func aLateFirstBufferAfterARestartIsStillToppedUp() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try writer.append(buffer(at: 0))
    // F460 under-estimates a restart's gap by one health tick: 9 s padded for an outage of 10 s.
    try writer.appendSilence(frames: 48_000 * 9)
    _ = try writer.append(buffer(at: 1_024 + 48_000 * 10))
    #expect(writer.droppedFrames == 48_000, "the remaining second of the outage was not topped up")
    // And a dropped second later on is still padded: no re-anchor moved the baseline.
    _ = try writer.append(buffer(at: 2 * 1_024 + 48_000 * 11))
    #expect(writer.droppedFrames == 2 * 48_000)
}

@Test("A first buffer after a restart stamped earlier than the restart's silence can explain moves nothing (F1050)")
func aWildStampAfterARestartIsNotAnAnchor() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for index in 0..<100 { _ = try writer.append(buffer(at: index * 1_024)) }
    try writer.appendSilence(frames: 48_000)
    // A second of silence cannot account for a buffer stamped back at the start of the track.
    _ = try writer.append(buffer(at: 0))
    // So the next buffer, on the old baseline's time, is not taken for a 30-second gap.
    _ = try writer.append(buffer(at: 101 * 1_024 + 48_000))
    #expect(writer.droppedFrames == 0, "a wild stamp became the anchor, and the next buffer was padded against it")
}
