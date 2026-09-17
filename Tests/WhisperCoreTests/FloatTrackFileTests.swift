import Foundation
import Testing
@testable import WhisperCore

// F278 — F276 shipped the periodic `F_FULLFSYNC` that bounds how much of a recording's tail a
// kernel panic or power cut can take. It closed with this Gap, in its own words:
//
//   "The sync is verified by reading, not by a test. `shouldSyncTrack`'s cadence is pinned, but no
//    test asserts that `fcntl` was actually called — `FloatTrackWriter` is `private` and
//    untestable, which is F278. So 'the sync happens' rests on the code being three lines long."
//
// Three lines is not the problem; being unobservable is. `FloatTrackWriter.append` takes a
// `CMSampleBuffer`, which no test can build without a live `SCStream`, so the durability guarantee
// and the format conversion were welded together and neither could be checked. `FloatTrackFile`
// takes the second half — the file, the byte accounting, the flush cadence — and injects the sync,
// so what these tests observe is the actual call, not a constant that a call happens to read.

private struct SyncSpy {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: [Int32] = []
        func record(_ descriptor: Int32) { lock.lock(); descriptors.append(descriptor); lock.unlock() }
        var all: [Int32] { lock.lock(); defer { lock.unlock() }; return descriptors }
    }

    private let box = Box()
    var sync: FloatTrackFile.DeviceSync { { [box] in box.record($0) } }
    var count: Int { box.all.count }
    var descriptors: [Int32] { box.all }
}

private func temporaryTrackURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("F278-track-\(UUID().uuidString).f32")
}

/// One interval's worth of frames, so the tests read in units of the cadence rather than bytes.
private let framesPerInterval = 64
private let interval = framesPerInterval * MemoryLayout<Float>.size

@Test("Appending a full interval flushes the track to the device (F278)")
func fullIntervalFlushes() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    try track.append([Float](repeating: 0.25, count: framesPerInterval))

    #expect(spy.count == 1)
    #expect(spy.descriptors.allSatisfy { $0 >= 0 }, "flushed a descriptor that was never opened")
}

@Test("A partial interval does not flush — the cadence is periodic, not per-write (F278)")
func partialIntervalDoesNotFlush() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    for _ in 0..<4 {
        try track.append([Float](repeating: 0.1, count: framesPerInterval / 8))
    }

    #expect(spy.count == 0, "flushed before an interval had accumulated")
}

@Test("The byte counter resets, so three intervals flush three times, not six (F278)")
func flushesOncePerInterval() throws {
    // The bug this would catch: forgetting `bytesSinceSync = 0`, which turns every subsequent write
    // into a device flush on the capture queue — 10 ms per audio buffer instead of per 5 s. That is
    // exactly the dropout F259 feared, arrived at by accident rather than by design.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    for _ in 0..<3 {
        try track.append([Float](repeating: 0.5, count: framesPerInterval))
    }

    #expect(spy.count == 3)
}

@Test("Finishing flushes the tail before anyone reads the track back (F278)")
func finishFlushesTheTail() throws {
    // `FloatTrackMixer` writes the WAV header LAST, so a truncated `meeting.wav` sends recovery to
    // these `.f32` tracks. Their durability is what that fallback rests on, so the final flush has
    // to happen even when the tail is shorter than an interval — which is the common case, since a
    // recording does not end on a 5-second boundary.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    try track.append([Float](repeating: 0.5, count: 3))
    #expect(spy.count == 0)

    try track.finish()
    #expect(spy.count == 1, "the tail was never flushed")
}

@Test("Finishing twice flushes once — finalizing is idempotent (F278)")
func finishIsIdempotent() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    try track.append([Float](repeating: 0.5, count: 3))
    try track.finish()
    try track.finish()

    #expect(spy.count == 1)
    // A second `finish` must not flush a closed descriptor: after `close()` the fd is invalid, and
    // in the worst case has been reused by another open file.
}

@Test("Appending after finish is ignored rather than corrupting the track (F278)")
func appendAfterFinishIsIgnored() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    try track.append([Float](repeating: 0.5, count: 4))
    try track.finish()
    try track.append([Float](repeating: 0.5, count: framesPerInterval))

    #expect(track.frameCount == 4, "wrote to a track that had already been finalized")
    #expect(spy.count == 1)
}

@Test("A track holds exactly the little-endian float32 samples it was given (F278)")
func samplesRoundTrip() throws {
    // The write path is what recovery reads back with `RawFloatReader`, so the byte layout is a
    // contract between the two, not an implementation detail.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })

    let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.123_456_79]
    try track.append(samples)
    try track.finish()

    let written = try Data(contentsOf: url)
    #expect(written.count == samples.count * 4)
    let readBack = written.withUnsafeBytes { raw -> [Float] in
        (0..<samples.count).map {
            Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
        }
    }
    #expect(readBack == samples)
    #expect(track.frameCount == Int64(samples.count))
}

@Test("A sync that does nothing still leaves a complete track on disk (F278)")
func aFailingSyncNeverFailsTheCapture() throws {
    // F276 ignores sync failures on purpose: a flush that does not happen leaves exactly the
    // exposure that existed before F276, and must never fail a capture that is otherwise working.
    // Losing the whole recording to protect its last five seconds is the wrong trade.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })

    for _ in 0..<3 {
        try track.append([Float](repeating: 0.25, count: framesPerInterval))
    }
    try track.finish()

    let written = try Data(contentsOf: url)
    #expect(written.count == 3 * interval)
}

@Test("Cancelling a track removes its file (F278)")
func cancelRemovesTheFile() throws {
    let url = temporaryTrackURL()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })
    try track.append([Float](repeating: 0.25, count: framesPerInterval))

    track.cancel()

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("The capture cadence is about five seconds of 48 kHz mono audio (F278)")
func defaultCadenceMatchesTheMeasuredChoice() {
    // Pinned here rather than only in `AudioCaptureEngine` so the constant and the mechanism that
    // consumes it live in the same place. 5 s bounds tail loss at ~10 ms per flush (measured p99
    // under load); nothing was measured to say 2 s or 10 s is better, which is F276's open Gap.
    #expect(FloatTrackFile.captureSyncIntervalBytes == 48_000 * 4 * 5)
    #expect(FloatTrackFile.captureSyncIntervalBytes / (48_000 * 4) == 5)

    // The boundary, at the point that actually decides. This moved off
    // `AudioCaptureEngine.shouldSyncTrack`, which after F278's split had no production caller left
    // and survived only to keep a test compiling — while still reading like the rule that governs
    // the cadence. `>=`, not `>`: at exactly one interval the flush is due.
    let interval = FloatTrackFile.captureSyncIntervalBytes
    #expect(!FloatTrackFile.shouldSync(bytesSinceSync: 0, interval: interval))
    #expect(!FloatTrackFile.shouldSync(bytesSinceSync: interval - 1, interval: interval))
    #expect(FloatTrackFile.shouldSync(bytesSinceSync: interval, interval: interval))
    #expect(FloatTrackFile.shouldSync(bytesSinceSync: interval * 3, interval: interval))
}

// MARK: - Writing the gap a restart could not capture (F275)

@Test("Silence padding writes exactly the frames it was asked for, as zeros (F275)")
func silencePaddingWritesZeroFrames() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })

    try track.append([Float](repeating: 0.5, count: 4))
    try track.appendSilence(frames: 10)
    try track.append([Float](repeating: 0.5, count: 4))
    try track.finish()

    #expect(track.frameCount == 18)
    let data = try Data(contentsOf: url)
    let samples = data.withUnsafeBytes { raw in
        (0..<18).map {
            Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
        }
    }
    // The point of padding at all: the samples after the gap sit at their true elapsed offset, so
    // every later timestamp still means what it says (F151 is what happens without this).
    #expect(Array(samples[0..<4]) == [Float](repeating: 0.5, count: 4))
    #expect(Array(samples[4..<14]) == [Float](repeating: 0, count: 10))
    #expect(Array(samples[14..<18]) == [Float](repeating: 0.5, count: 4))
}

@Test("A large gap is padded without holding it all in memory (F275)")
func largePaddingIsChunked() throws {
    // Five minutes — the policy's cap — is 14.4 M frames per track. Allocating that as one array
    // would be a 57 MB spike on the capture path; the write has to chunk.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })

    let frames = CaptureRestartPolicy.paddingFrames(forGap: 5 * 60, sampleRate: 48_000)
    #expect(frames == 14_400_000)
    try track.appendSilence(frames: frames)
    try track.finish()

    #expect(track.frameCount == frames)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(size == Int(frames) * 4)
}

@Test("A zero or negative gap writes nothing (F275)")
func nonPositivePaddingIsANoOp() throws {
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: { _ in })

    try track.appendSilence(frames: 0)
    try track.appendSilence(frames: -5)
    try track.finish()

    #expect(track.frameCount == 0)
    #expect(try Data(contentsOf: url).isEmpty)
}

@Test("Padding is flushed on the same cadence as captured audio (F275)")
func paddingParticipatesInTheSyncCadence() throws {
    // Padding is real bytes on the same track, so it must not slip past the durability rule: a
    // crash just after a long pad should lose no more than a captured span of the same size.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    try track.appendSilence(frames: Int64(framesPerInterval) * 3)

    // Once, not three times. This test first asserted three, which was wrong about what a flush
    // is: `F_FULLFSYNC` flushes everything written to the descriptor so far, so three calls in
    // immediate succession would cost three round trips and make two of them no-ops.
    #expect(spy.count == 1)
}

@Test("A write spanning several intervals does not lose its sync credit (F275)")
func oversizedWriteKeepsTheCadenceHonest() throws {
    // The bug the test above found. `bytesSinceSync = 0` after a flush discards up to a full
    // interval of credit, so each oversized write pushes the next flush later than the rule
    // promises — the bound "at most one interval unflushed" quietly stops holding. Invisible on the
    // capture path (a buffer is ~16 KB against 960 KB) and very visible once padding writes in
    // 32 KB chunks.
    let url = temporaryTrackURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let spy = SyncSpy()
    let track = try FloatTrackFile(url: url, syncIntervalBytes: interval, sync: spy.sync)

    // 1.5 intervals: flushes once, and half an interval of credit must survive.
    try track.append([Float](repeating: 0.5, count: framesPerInterval + framesPerInterval / 2))
    #expect(spy.count == 1)

    // Half an interval more reaches the next boundary exactly. Zeroing would leave this short.
    try track.append([Float](repeating: 0.5, count: framesPerInterval / 2))
    #expect(spy.count == 2, "the carried remainder was discarded, so the cadence drifted")
}
