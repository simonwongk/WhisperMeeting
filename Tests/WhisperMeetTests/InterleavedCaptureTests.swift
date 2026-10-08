import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F875 — meeting capture threw on every interleaved buffer with 2 or more channels.
//
// `FloatTrackWriter.append` sized the `AudioBufferList` it hands CoreMedia as one buffer per channel.
// An interleaved buffer has ONE buffer holding every channel, and CoreMedia refuses a list of any other
// size: `kCMSampleBufferError_ArrayTooSmall` (-12737, `CMSampleBuffer.h:100`), oversized included, which
// the header's "insufficient" does not say. The review measured it with the writer's exact call for
// 2- and 4-channel interleaved float and 2-channel Int16, and the real `append` threw
// `conversionFailed("Could not read captured audio (-12737)")` on interleaved Int16 at 2 and 4
// channels. The microphone arrives in "the selected microphone capture device's native format"
// (`SCStream.h:26`), so a device that delivers interleaved multi-channel audio recorded nothing for the
// whole meeting. Older than Wave 4 (since `bfad929`).
//
// The header says how big the list must be: `bufferListOut` is "Allocated by the caller, sized as
// specified by bufferListSizeNeededOut" (`CMSampleBuffer.h:875`). So the writer now asks.

/// One fixture: how the samples are stored.
struct CapturedShape: CustomTestStringConvertible, Sendable {
    let channels: UInt32
    let float: Bool
    let interleaved: Bool

    var testDescription: String {
        "\(channels) ch \(float ? "float32" : "Int16") \(interleaved ? "interleaved" : "deinterleaved")"
    }
}

private let shapes: [CapturedShape] = [
    CapturedShape(channels: 2, float: true, interleaved: true),
    CapturedShape(channels: 4, float: true, interleaved: true),
    CapturedShape(channels: 2, float: false, interleaved: true),
    CapturedShape(channels: 4, float: false, interleaved: true),
    // Controls: the deinterleaved shapes recorded before the fix, and must still.
    CapturedShape(channels: 2, float: true, interleaved: false),
    CapturedShape(channels: 4, float: false, interleaved: false),
]

@Test("An interleaved multi-channel buffer is recorded through the real append, averaged (F875)", arguments: shapes)
func interleavedCaptureIsRecorded(_ shape: CapturedShape) throws {
    let url = try CapturedSampleBuffer.temporaryTrackURL("F875")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try FloatTrackWriter(outputURL: url, targetSampleRate: CapturedSampleBuffer.rate)

    // Two consecutive 1,024-frame buffers, the size ScreenCaptureKit hands over, each with a 0.5 tone
    // in the last channel only.
    let first = try CapturedSampleBuffer.make(
        channels: shape.channels, frames: 1_024, float: shape.float, interleaved: shape.interleaved
    )
    let second = try CapturedSampleBuffer.make(
        channels: shape.channels, frames: 1_024, startFrame: 1_024, float: shape.float, interleaved: shape.interleaved
    )
    let level = try #require(try writer.append(first), "\(shape.testDescription): append returned no level")
    _ = try #require(try writer.append(second))
    let track = try writer.finish()

    // Reads correctly: every frame is on disk once, and the tone is there at the average of the channels.
    #expect(track.frameCount == 2_048, "\(shape.testDescription)")
    let recorded = try CapturedSampleBuffer.samples(of: track)
    let peak = recorded.reduce(0) { max($0, abs($1)) }
    let expected = Float(0.5) / Float(shape.channels)
    #expect(abs(peak - expected) < expected * 0.01, "\(shape.testDescription): peak \(peak), expected \(expected)")
    #expect(abs(level.peak - expected) < expected * 0.01, "\(shape.testDescription): meter \(level.peak)")
}
