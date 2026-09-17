import Foundation
import Testing
@testable import WhisperCore

// F256 — a read error partway through a raw track must truncate, not become silence.
//
// `RawFloatReader.read` returned zero-filled samples for BOTH a genuine I/O error and end of file.
// EOF zero-padding is intended and load-bearing — the two `.f32` files are written independently
// from one capture callback, so an abrupt stop leaves them ragged and the shorter one must pad.
// An I/O error is data loss. Because `totalFrames` comes from the file SIZE, the loop ran to the
// declared length and wrote silence for every remaining chunk, then returned normally with the
// ordinary "recovered from source audio" notice.
//
// A real I/O error cannot be produced with a real file and permission tricks are flaky, so the mix
// takes its two reads AND its write as closures. The write is injected too, not just the reads: the
// loop streams each chunk out as it goes, and returning the PCM instead would mean holding ~345 MB
// in memory for a 60-minute meeting.

private struct ReadFailure: Error {}

@Test("A clean mix writes every frame and reports no truncation")
func cleanMixWritesEverything() throws {
    var written: [Int16] = []
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 300,
        chunkSize: 100,
        readSystem: { [Float](repeating: 0.5, count: $0) },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    #expect(result.writtenFrames == 300)
    #expect(result.truncation == nil)
    #expect(written.count == 300)
}

@Test("A read error truncates at the failing chunk and keeps the readable prefix")
func readErrorTruncatesAtTheFailingChunk() throws {
    var written: [Int16] = []
    var call = 0
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 1_000,
        chunkSize: 100,
        readSystem: { count in
            call += 1
            if call == 3 { throw ReadFailure() }   // fails on the third chunk
            return [Float](repeating: 0.5, count: count)
        },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    // Exactly two chunks survive — not 1,000 frames with 800 of silence.
    #expect(result.writtenFrames == 200)
    #expect(written.count == 200)
    #expect(result.truncation?.frame == 200)
    #expect(result.truncation?.error is ReadFailure)
}

@Test("Either track failing truncates the mix")
func microphoneFailureAlsoTruncates() throws {
    var call = 0
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 500,
        chunkSize: 100,
        readSystem: { [Float](repeating: 0.5, count: $0) },
        readMicrophone: { count in
            call += 1
            if call == 2 { throw ReadFailure() }
            return [Float](repeating: 0.1, count: count)
        },
        write: { _ in }
    )
    // The output is one mixed stream, so it stops where EITHER side became unreadable. Keeping one
    // channel past that point would silently change the mix from two channels to one partway
    // through.
    #expect(result.writtenFrames == 100)
    #expect(result.truncation?.frame == 100)
}

@Test("A failure on the very first chunk writes nothing at all")
func firstChunkFailureWritesNothing() throws {
    var written: [Int16] = []
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 500,
        chunkSize: 100,
        readSystem: { _ in throw ReadFailure() },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    #expect(result.writtenFrames == 0)
    #expect(written.isEmpty)
    #expect(result.truncation?.frame == 0)
}

@Test("A short final chunk is sized to what remains, never over-read")
func finalChunkIsSizedToTheRemainder() throws {
    var requested: [Int] = []
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 250,
        chunkSize: 100,
        readSystem: { count in requested.append(count); return [Float](repeating: 0, count: count) },
        readMicrophone: { [Float](repeating: 0, count: $0) },
        write: { _ in }
    )
    #expect(requested == [100, 100, 50])
    #expect(result.writtenFrames == 250)
    #expect(result.truncation == nil)
}
