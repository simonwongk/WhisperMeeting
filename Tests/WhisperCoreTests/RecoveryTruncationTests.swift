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

// MARK: - The truncation floor

@Test("A rebuild that can read nothing throws instead of indexing an empty meeting")
func zeroReadableFramesThrows() throws {
    // The floor, and the Critical a reviewer found in the design before any of this was written.
    //
    // Without it: `writtenFrames == 0` gives `dataByteCount == 0`, so a 44-byte WAV that
    // `wavDuration` refuses — yet `recover` still returned a `RecoveredRecording`, and `AppModel`'s
    // `duration <= 0` rescue is gated on `.importedRecording` so it never fired. A duration-0
    // meeting would be indexed over an empty WAV carrying the ORDINARY "recovered" message, its
    // UUID would enter `indexedIDs`, and `orphanedRecordings()` would exclude the folder
    // permanently — stranding intact `.f32` tracks with no route back. Strictly worse than the bug
    // this ticket fixes.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryFloor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }

    // `frameCount` reads the file SIZE, so `totalFrames` is non-zero while every read fails.
    let path = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    }

    #expect(throws: (any Error).self) {
        _ = try InterruptedRecordingRecovery.recover(in: directory)
    }
    // Nothing was left behind pretending to be a recording.
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("meeting-recovered.wav").path
        )
    )
    // And the raw track the user still needs is untouched.
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test("A readable rebuild reports no truncation and keeps its full duration")
func readableRebuildIsNotTruncated() throws {
    // The counterpart: the floor must not make an ordinary rebuild look damaged.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryWhole-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // One second of 48 kHz float32 in each track, equal length.
    let samples = [Float](repeating: 0.2, count: 48_000)
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try samples.withUnsafeBytes {
            try Data($0).write(to: directory.appendingPathComponent(name))
        }
    }

    let recovered = try #require(try InterruptedRecordingRecovery.recover(in: directory))
    #expect(recovered.source == .rebuiltSourceTracks)
    #expect(recovered.truncatedAtSeconds == nil)
    #expect(recovered.expectedDurationSeconds == 1.0)
    #expect(!recovered.isSeverelyTruncated)
    #expect(abs(recovered.duration - 1.0) < 0.001)
}
