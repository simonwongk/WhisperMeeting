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

// Two calls below warn "no calls to throwing functions occur within 'try' expression", because
// `mixTracks` is `rethrows` and those two pass non-throwing closures. The `try` is deliberately
// LEFT IN PLACE. Removing it is safe only if Swift 6.1 — the CI runner's compiler, older than the
// one here — agrees that the call cannot throw. `rethrows` inference is stable across both as far
// as anyone can tell, but "as far as anyone can tell" is exactly what put a red commit on main on
// 2026-09-17: an array literal that 6.3 types `[Int64]` and 6.1 types `[Int]`. A warning here
// costs a line of CI log; guessing wrong costs a red main. If you want these gone, verify against
// 6.1 first, and note that a warning-free build is not worth a push to find out.

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

@Test("A rebuild whose first chunk is unreadable throws instead of indexing an empty meeting")
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
    //
    // This goes through the injected opener, and the reason is worth stating because the obvious
    // version of this test does not work: `chmod 0o000` on the track, and equally pointing the
    // name at a directory, both throw from `FileHandle(forReadingFrom:)` — BEFORE the mix — so the
    // floor is never consulted and the test passes while covering nothing. Production reaches the
    // floor by a route a test cannot manufacture: a bad block in the first chunk of a file that
    // opens perfectly well.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryFloor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // `frameCount` reads the file SIZE, so `totalFrames` is non-zero while every read fails.
    let path = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: path)

    #expect(throws: ReadFailure.self) {
        _ = try InterruptedRecordingRecovery.recover(
            in: directory,
            sampleRate: 48_000,
            openTrack: { _ in { _ in throw ReadFailure() } }
        )
    }
    // Nothing was left behind pretending to be a recording: the 44-byte stub whose header was
    // never written is removed, so the folder still looks like the interrupted capture it is and
    // the next launch retries.
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("meeting-recovered.wav").path
        )
    )
    // And the raw track the user still needs is untouched.
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test("A rebuild whose track cannot even be opened throws and leaves the folder alone")
func unopenableTrackThrows() throws {
    // The neighbouring failure, through the real opener. This is what `chmod 0o000` actually
    // exercises — `FileHandle(forReadingFrom:)` failing with EACCES — which is a different branch
    // from the floor above and worth holding on its own: the stub must be cleaned up here too,
    // and that cleanup runs from a `defer` armed before the reader is ever constructed.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryUnopenable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    }

    #expect(throws: (any Error).self) {
        _ = try InterruptedRecordingRecovery.recover(in: directory)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("meeting-recovered.wav").path
        )
    )
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test("A rebuild that keeps only its first chunks is truncated, not failed")
func partialReadIsKeptNotDiscarded() throws {
    // The floor's counterpart at the other end: once ANY frames are readable the recovery
    // succeeds, short, and says where it stops. The floor must not swallow a partial rebuild.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryPartial-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Four seconds of declared audio at 48 kHz; the reader dies after the first 8,192-frame chunk.
    try Data(repeating: 0, count: 192_000 * 4)
        .write(to: directory.appendingPathComponent("system-audio.f32"))

    var chunk = 0
    let recovered = try #require(try InterruptedRecordingRecovery.recover(
        in: directory,
        sampleRate: 48_000,
        openTrack: { url in
            guard url != nil else { return { [Float](repeating: 0, count: $0) } }
            return { count in
                chunk += 1
                if chunk > 1 { throw ReadFailure() }
                return [Float](repeating: 0.5, count: count)
            }
        }
    ))
    #expect(recovered.source == .rebuiltSourceTracks)
    #expect(recovered.truncatedAtSeconds == 8_192.0 / 48_000)
    #expect(recovered.expectedDurationSeconds == 4.0)
    #expect(abs(recovered.duration - 8_192.0 / 48_000) < 0.0001)
    // 0.17s of an expected 4s is under a tenth: the meeting is not presented as an ordinary one.
    #expect(recovered.isSeverelyTruncated)
    // The WAV on disk declares the truncated length, not the length the tracks promised.
    let wav = try Data(contentsOf: recovered.recordingURL)
    let declared = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self).littleEndian }
    #expect(Int(declared) == 8_192 * 2)
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
