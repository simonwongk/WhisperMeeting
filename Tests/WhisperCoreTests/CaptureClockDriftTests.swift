import Foundation
import Testing
@testable import WhisperCore

// F556 — `CaptureGapPolicy` compared each buffer's presentation offset with the frames written and
// padded the whole difference once it passed 480 frames (10 ms). That is right for a dropped buffer,
// which arrives as one step, and wrong for a device whose sample clock runs slightly off host time,
// which builds the same difference up a fraction of a frame per buffer. A microphone 50 ppm slow got a
// 10 ms block of zeros written into it every 200 s, mid-speech; one 50 ppm fast ran ahead of the other
// track with nothing correcting it, since an early buffer is never padded.
//
// Drift is now steered inside the band the gap policy ignores: past `driftToleranceFrames` (5 ms) a
// buffer's first frame is written twice, or left out, one frame per buffer. A step past 10 ms is still
// F151's gap, padded whole; an early step past 10 ms is still left alone, as F151 decided.
//
// No ScreenCaptureKit clock can be made to drift on demand, so the clock is synthetic: host-time
// presentation offsets for a device producing `bufferFrames` per buffer at 48 kHz × (1 + ppm/1e6),
// replayed through `FloatTrackFile.appendCaptured`, the call `FloatTrackWriter.append` makes.

private let rate: Double = 48_000

private struct Run {
    var gapsPadded: [Int64] = []
    var repeated = 0
    var skipped = 0
    /// The worst `round(offset × rate) − written` seen before any buffer, in frames.
    var worstLag: Int64 = 0
    var worstLead: Int64 = 0
    var framesWritten: Int64 = 0
    var finalOffsetFrames: Int64 = 0
}

/// `ppm` > 0 is a device clock running SLOW against host time: each buffer spans a little more host
/// time than its frames say. `jitterFrames` adds a deterministic ± jitter to every timestamp.
/// `drop` removes the buffers whose offsets fall in that many seconds starting at `at`.
private func replay(
    ppm: Double,
    seconds: Double,
    bufferFrames: Int = 1_024,
    jitterFrames: Int = 0,
    drop: (at: Double, seconds: Double)? = nil
) throws -> Run {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F556-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Nothing reaches the disk: this is about the accounting, over half an hour of buffers.
    let track = try FloatTrackFile(
        url: directory.appendingPathComponent("track.f32"),
        syncIntervalBytes: .max, sync: { _ in }, writer: { _, _ in }
    )
    let samples = [Float](repeating: 0.25, count: bufferFrames)
    let hostSecondsPerBuffer = Double(bufferFrames) / rate * (1 + ppm / 1_000_000)
    let count = Int(seconds / hostSecondsPerBuffer)
    var lcg: UInt64 = 0x5EED_F556
    var run = Run()
    for index in 0..<count {
        var offset = Double(index) * hostSecondsPerBuffer
        if let drop, offset >= drop.at, offset < drop.at + drop.seconds { continue }
        if jitterFrames > 0 {
            lcg = lcg &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(lcg >> 11) / Double(1 << 53)          // [0, 1)
            offset += (unit * 2 - 1) * Double(jitterFrames) / rate
            offset = max(0, offset)
        }
        let discrepancy = Int64((offset * rate).rounded()) - track.frameCount
        let done = try samples.withUnsafeBufferPointer { buffer in
            try track.appendCaptured(
                buffer.baseAddress!, frameCount: bufferFrames,
                presentationOffset: offset, sampleRate: rate
            )
        }
        switch done {
        case let .padSilence(frames):
            // A gap's own discrepancy is F151's to measure, not the drift's.
            run.gapsPadded.append(frames)
        case .none, .repeatFirstFrame, .skipFirstFrame:
            run.worstLag = max(run.worstLag, discrepancy)
            run.worstLead = min(run.worstLead, discrepancy)
        }
        if done == .repeatFirstFrame { run.repeated += 1 }
        if done == .skipFirstFrame { run.skipped += 1 }
        run.finalOffsetFrames = Int64((offset * rate).rounded()) + Int64(bufferFrames)
    }
    run.framesWritten = track.frameCount
    return run
}

/// A buffer's own lag or lead may be up to the drift tolerance, plus the one frame the buffer before
/// it could not yet correct, plus the jitter on its own timestamp.
private func bound(jitter: Int = 0) -> Int64 { Int64(CaptureGapPolicy.driftToleranceFrames + 1 + jitter) }

@Test("A device clock 50 ppm slow gets no 10 ms holes of silence over half an hour, and stays on the clock (F556)")
func aSlowClockGetsNoSilenceHoles() throws {
    let run = try replay(ppm: 50, seconds: 1_800)
    // Before F556: eight 481-frame blocks of zeros, one every ~200 s, mid-speech.
    #expect(run.gapsPadded.isEmpty, "silence written into a drifting track: \(run.gapsPadded)")
    #expect(run.worstLag <= bound(), "the track fell \(run.worstLag) frames behind the clock")
    // 2.4 frames a second for 1,800 s, less the 240 the tolerance lets stand: one frame at a time.
    #expect(run.repeated > 3_900 && run.repeated < 4_400, "\(run.repeated)")
    #expect(run.skipped == 0)
    #expect(abs(run.finalOffsetFrames - run.framesWritten) <= bound(), "ends \(run.finalOffsetFrames - run.framesWritten) frames off")
}

@Test("A device clock 50 ppm fast is steered back instead of running ahead of the other track (F556)")
func aFastClockStaysOnTheClock() throws {
    let run = try replay(ppm: -50, seconds: 1_800)
    // Before F556: nothing corrected it, and it ran 4,320 frames (90 ms) ahead by the end.
    #expect(-run.worstLead <= bound(), "the track ran \(-run.worstLead) frames ahead of the clock")
    #expect(run.gapsPadded.isEmpty)
    #expect(run.skipped > 3_900 && run.skipped < 4_400, "\(run.skipped)")
    #expect(run.repeated == 0)
}

@Test("A healthy clock with a millisecond of timestamp jitter is left exactly as it was (F556 control)")
func aHealthyClockWithJitterIsUntouched() throws {
    let run = try replay(ppm: 0, seconds: 600, jitterFrames: 48)
    #expect(run.gapsPadded.isEmpty && run.repeated == 0 && run.skipped == 0,
            "pads \(run.gapsPadded.count), repeats \(run.repeated), skips \(run.skipped)")
}

@Test("A slow clock's jitter costs no silence and keeps the track within the tolerance plus the jitter (F556)")
func aSlowClockWithJitterStaysBounded() throws {
    let run = try replay(ppm: 50, seconds: 600, jitterFrames: 96)
    #expect(run.gapsPadded.isEmpty, "\(run.gapsPadded)")
    #expect(run.worstLag <= bound(jitter: 96), "\(run.worstLag)")
    #expect(-run.worstLead <= bound(jitter: 96), "\(run.worstLead)")
}

@Test("A dropped second inside a drifting stream is still padded whole, once (F556 keeps F151)")
func aDropInADriftingStreamIsStillPadded() throws {
    let run = try replay(ppm: 50, seconds: 900, drop: (at: 600, seconds: 1))
    #expect(run.gapsPadded.count == 1, "\(run.gapsPadded)")
    let gap = try #require(run.gapsPadded.first)
    // The missing second, plus at most the drift the tolerance had let stand when it happened.
    #expect(gap >= 48_000 - 1_024 && gap <= 48_000 + 1_024 + bound(), "\(gap)")
    #expect(abs(run.finalOffsetFrames - run.framesWritten) <= bound())
}

@Test("The drift band: a frame repeated or left out only between 5 ms and 10 ms, a gap past 10 ms padded, an early step past 10 ms left alone (F556)")
func theDriftBandEdges() {
    let tolerance = Int64(CaptureGapPolicy.driftToleranceFrames)
    let gap = Int64(CaptureGapPolicy.toleranceFrames)
    func decide(_ discrepancy: Int64, bufferFrames: Int = 1_024) -> CaptureAlignment {
        CaptureGapPolicy.alignment(
            presentationOffset: Double(48_000 + discrepancy) / rate,
            writtenFrames: 48_000, bufferFrames: bufferFrames, sampleRate: rate
        )
    }
    #expect(decide(0) == .none)
    #expect(decide(tolerance) == .none)
    #expect(decide(tolerance + 1) == .repeatFirstFrame)
    #expect(decide(gap) == .repeatFirstFrame)
    #expect(decide(gap + 1) == .padSilence(gap + 1), "F151's gap, whole")
    #expect(decide(-tolerance) == .none)
    #expect(decide(-tolerance - 1) == .skipFirstFrame)
    #expect(decide(-gap) == .skipFirstFrame)
    #expect(decide(-gap - 1) == .none, "F151: an early step is left alone, never truncated")
    #expect(decide(-tolerance - 1, bufferFrames: 1) == .none, "a one-frame buffer is never emptied")
    #expect(decide(tolerance + 1, bufferFrames: 0) == .none, "an empty buffer has no frame to repeat")
    for wild in [Double.nan, .infinity, -.infinity, -1, 1e30] {
        let decision = CaptureGapPolicy.alignment(
            presentationOffset: wild, writtenFrames: 48_000, bufferFrames: 1_024, sampleRate: rate
        )
        if wild == 1e30 {
            #expect(decision == .padSilence(Int64(CaptureGapPolicy.maximumGapFrames)), "the F151 cap still holds")
        } else {
            #expect(decision == .none, "\(wild): \(decision)")
        }
    }
}

@Test("A repeated frame is the buffer's own first sample written twice, and a skipped one is left out (F556)")
func theCorrectionsWriteRealSamples() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F556-bytes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("track.f32")
    let track = try FloatTrackFile(url: url, syncIntervalBytes: .max, sync: { _ in })
    let lead = [Float](repeating: 0, count: 1_000)
    let second: [Float] = [5, 6, 7, 8]
    let third: [Float] = [9, 10, 11, 12]
    func append(_ samples: [Float], at frame: Int64) throws -> CaptureAlignment {
        try samples.withUnsafeBufferPointer {
            try track.appendCaptured(
                $0.baseAddress!, frameCount: $0.count, presentationOffset: Double(frame) / rate, sampleRate: rate
            )
        }
    }
    #expect(try append(lead, at: 0) == .none)
    // 300 frames late against the 1,000 written: `5` goes in twice.
    #expect(try append(second, at: 1_300) == .repeatFirstFrame)
    // 300 frames early against the 1,005 written: `9` is left out.
    #expect(try append(third, at: 1_005 - 300) == .skipFirstFrame)
    #expect(track.frameCount == 1_008)
    try track.finish()
    let data = try Data(contentsOf: url)
    let written = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let tail: [Float] = Array(written.suffix(8))
    let expected: [Float] = [5, 5, 6, 7, 8, 10, 11, 12]
    #expect(written.count == 1_008)
    #expect(tail == expected, "\(tail)")
}
