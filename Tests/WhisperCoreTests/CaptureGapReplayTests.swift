import Foundation
import Testing
@testable import WhisperCore

// F301 / F151 — a mid-capture buffer drop, driven through the real writer.
//
// F151 asked to "induce a mid-capture drop and compare channel alignment vs wall-clock", and
// `CaptureGapPolicyTests` covers the policy's arithmetic in isolation. What was untested is the
// thing that actually goes wrong: the policy's *interaction* with `FloatTrackFile`'s byte
// accounting, over a sequence of buffers, on two channels that drop independently.
//
// ScreenCaptureKit will not drop buffers on demand, so the drop comes from the seam instead. The
// replay below performs exactly the two calls `AudioCaptureEngine` makes per buffer, in that order
// (`Sources/WhisperMeet/AudioCaptureEngine.swift:713-724`): ask the policy for padding against the
// frames written so far, append that many silent frames, then append the buffer.
//
// What this does NOT cover, said plainly rather than implied: the `CMSampleBuffer` plumbing above
// that call — the converter, `firstPresentationTime`, and the queue it runs on. This is the writer
// and the policy together, which is the pair whose accounting could disagree.

private let replayRate: Double = 48_000

/// One channel's buffer sequence, replayed through the engine's own two calls.
///
/// `padded` is returned rather than asserted inside, so a test can distinguish "the length is right"
/// from "the length is right *because* of padding" — a writer that happened to be long for another
/// reason would otherwise pass.
@discardableResult
private func replay(
    _ buffers: [(offset: Double, frames: Int)],
    into track: FloatTrackFile,
    padding applyPadding: Bool = true
) throws -> Int64 {
    var padded: Int64 = 0
    for buffer in buffers {
        if applyPadding {
            let gap = CaptureGapPolicy.paddingFrames(
                presentationOffset: buffer.offset,
                writtenFrames: track.frameCount,
                sampleRate: replayRate
            )
            if gap > 0 {
                try track.appendSilence(frames: gap)
                padded += gap
            }
        }
        try track.append([Float](repeating: 0.5, count: buffer.frames))
    }
    return padded
}

/// A healthy stream: 100 ms buffers, each arriving exactly when the previous one ended.
///
/// Offsets are computed from the buffer index, never accumulated. The first draft added 0.1 in a
/// loop, and ten of those fall a rounding error short of 1.0 — so a "one second" stream emitted
/// eleven buffers and three of these tests failed against correct production code. A generator that
/// is wrong in the same units as the thing it measures is an unusually convincing way to be wrong.
private func healthyStream(seconds: Double, from start: Double = 0) -> [(offset: Double, frames: Int)] {
    let perBuffer = 0.1
    let count = Int((seconds / perBuffer).rounded())
    return (0..<count).map { index in
        (offset: start + Double(index) * perBuffer, frames: Int(perBuffer * replayRate))
    }
}

private func temporaryTrack(_ name: String, _ body: (FloatTrackFile, URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gap-replay-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("track.f32")
    // No device flush: this test is about accounting, and `F_FULLFSYNC` per 960 KB would make it
    // slow for nothing.
    let track = try FloatTrackFile(url: url, syncIntervalBytes: .max, sync: { _ in })
    try body(track, url)
}

@Test("A healthy capture pads nothing and lands exactly on wall-clock (F301)")
func healthyCaptureIsUntouched() throws {
    try temporaryTrack("healthy") { track, _ in
        let padded = try replay(healthyStream(seconds: 2.0), into: track)
        #expect(padded == 0, "a healthy stream must cost no padding at all")
        #expect(track.frameCount == Int64(2.0 * replayRate))
    }
}

@Test("A two-second drop is padded so later samples keep their true offset (F301)")
func aDropIsPaddedToWallClock() throws {
    try temporaryTrack("drop") { track, _ in
        // One second of audio, then the stream goes quiet for two seconds and resumes.
        let buffers = healthyStream(seconds: 1.0) + healthyStream(seconds: 1.0, from: 3.0)
        let padded = try replay(buffers, into: track)

        // The recording must be as long as the wall-clock it spans: 4 s from the first buffer's
        // presentation time to the end of the last one.
        #expect(track.frameCount == Int64(4.0 * replayRate))
        // And the extra length must come from padding, not from anywhere else.
        #expect(padded == Int64(2.0 * replayRate))
    }
}

@Test("Without the padding call the same stream comes back two seconds short (F301)")
func withoutPaddingTheRecordingShortens() throws {
    // The sabotage, as an assertion rather than a step someone has to remember. If the padding is
    // ever removed from the engine, `aDropIsPaddedToWallClock` fails and this one still passes —
    // together they say the length is *caused* by the padding.
    try temporaryTrack("unpadded") { track, _ in
        let buffers = healthyStream(seconds: 1.0) + healthyStream(seconds: 1.0, from: 3.0)
        try replay(buffers, into: track, padding: false)
        #expect(track.frameCount == Int64(2.0 * replayRate))
        #expect(track.frameCount < Int64(4.0 * replayRate))
    }
}

@Test("Two channels dropping at different moments still end the same length (F301)")
func independentDropsDoNotDesyncTheChannels() throws {
    // The failure F151's comment names: "the two channels, which drop independently". System audio
    // and the microphone are separate streams, so a gap in one and not the other is the normal
    // case, and any per-channel arithmetic error shows up as the mix drifting out of sync — which
    // is far harder to notice than a short file.
    let systemGap = healthyStream(seconds: 1.0) + healthyStream(seconds: 7.0, from: 3.0)
    let microphoneGap = healthyStream(seconds: 5.0) + healthyStream(seconds: 4.0, from: 6.0)

    var lengths: [Int64] = []
    for (name, buffers) in [("system", systemGap), ("microphone", microphoneGap)] {
        try temporaryTrack(name) { track, _ in
            try replay(buffers, into: track)
            lengths.append(track.frameCount)
        }
    }
    #expect(lengths.count == 2)
    #expect(lengths[0] == lengths[1], "the two channels drifted apart: \(lengths)")
    #expect(lengths[0] == Int64(10.0 * replayRate))
}

@Test("Padded frames are real zeros on disk, not just a counter (F301)")
func paddingIsWrittenNotCountedOnly() throws {
    try temporaryTrack("bytes") { track, url in
        let buffers = healthyStream(seconds: 0.5) + healthyStream(seconds: 0.5, from: 1.5)
        try replay(buffers, into: track)
        try track.finish()

        // Byte accounting first: `frameCount` is the writer's own tally, so a file shorter than it
        // claims would desync everything downstream while every in-memory assertion still passed.
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == Int(track.frameCount) * MemoryLayout<Float>.size)

        let data = try Data(contentsOf: url)
        let samples = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        #expect(samples.count == Int(track.frameCount))

        // The gap region is silence and the audio regions are not, so the padding landed in the
        // right *place* — a writer that appended the silence after the buffer would pass every
        // length check above and put the audio at the wrong offset, which is the whole bug.
        let firstAudio = Int(0.25 * replayRate)
        let insideGap = Int(1.0 * replayRate)
        let afterGap = Int(1.75 * replayRate)
        #expect(samples[firstAudio] == 0.5)
        #expect(samples[insideGap] == 0)
        #expect(samples[afterGap] == 0.5)
    }
}

@Test("An absurd presentation time is capped rather than padding forever (F301)")
func anAbsurdJumpIsCapped() throws {
    try temporaryTrack("capped") { track, _ in
        // A stalled or garbage clock must not turn into hours of silence on disk. The policy caps a
        // single gap at `maximumGapFrames`; this asserts the cap survives contact with the writer,
        // which is where an unbounded `appendSilence` would actually cost the disk.
        //
        // The cap is defended twice on purpose — clamped in the Double domain before the conversion
        // (so the conversion cannot trap) and again with `min` after it — and each is sufficient
        // alone, which the policy's own comment says. So removing either one leaves this test green,
        // and that is not a gap in the test: it asserts the *property*, and the property still
        // holds. With both removed it fails, having written 4,147,204,800 frames — 16.6 GB of
        // silence in 7.4 s. That number is the reason the cap exists, measured rather than feared.
        let buffers = healthyStream(seconds: 0.5) + [(offset: 86_400.0, frames: 4_800)]
        try replay(buffers, into: track)
        let cap = Int64(CaptureGapPolicy.maximumGapFrames)
        #expect(track.frameCount <= Int64(0.5 * replayRate) + cap + 4_800)
        #expect(track.frameCount > cap, "the cap should still have padded up to its limit")
    }
}

// MARK: - F397: a run of failed WRITES, as distinct from a run of dropped buffers

/// Replays a stream in which the sample writes for `failing` indices do not land.
///
/// Distinct from `replay(_:into:padding:)` above in shape rather than arithmetic. In a *drop* no
/// buffer arrives, so no offset is consumed. Here every buffer arrives on time and it is the
/// append that fails, which is the write-failure case. Production computes the padding **before**
/// the sample write (`AudioCaptureEngine.append`), so the order below is that order.
///
/// The failure is modelled by not writing, the way this file already models a drop the
/// `SCStream` will not perform on demand: what a throw leaves behind is precisely samples that
/// were not written, and `FloatTrackFile` has no accounting for an attempt.
@discardableResult
private func replayWithFailedWrites(
    _ buffers: [(offset: Double, frames: Int)],
    failing: Range<Int>,
    into track: FloatTrackFile
) throws -> Int64 {
    var padded: Int64 = 0
    for (index, buffer) in buffers.enumerated() {
        let gap = CaptureGapPolicy.paddingFrames(
            presentationOffset: buffer.offset,
            writtenFrames: track.frameCount,
            sampleRate: replayRate
        )
        if gap > 0 {
            try track.appendSilence(frames: gap)
            padded += gap
        }
        guard !failing.contains(index) else { continue }
        try track.append([Float](repeating: 0.5, count: buffer.frames))
    }
    return padded
}

@Test("A run of failed writes leaves the timeline honest rather than shifted (F397)")
func failedWritesAreReconciledToWallClock() throws {
    // This pins the property the F397 decision rests on. The product's documented answer to "should
    // a capture whose writes keep failing stop itself?" is no — it is reported loudly and left
    // running — and that is only defensible because continuing is *honest*: if a failed write
    // shifted the timeline, every timestamp after it would be wrong and stopping would be the
    // better choice. The argument lives in `docs/PRODUCT_SPEC.md`; the property lives here, so
    // that changing the behaviour breaks a test rather than quietly falsifying a decision.
    try temporaryTrack("failed-writes") { track, _ in
        // Three seconds of 100 ms buffers; the writes for one full second of them fail.
        let buffers = healthyStream(seconds: 3.0)
        let padded = try replayWithFailedWrites(buffers, failing: 10..<20, into: track)

        #expect(track.frameCount == Int64(3.0 * replayRate),
                "the track must still span the wall-clock it covers")
        #expect(padded == Int64(1.0 * replayRate),
                "and the lost second must be made up as silence, not closed up")
    }
}

@Test("Without the padding the same failed writes shift everything after them (F397)")
func failedWritesWithoutPaddingShiftTheTimeline() throws {
    // The sabotage, as an assertion. Together with the test above this says the honest timeline is
    // *caused* by the reconciliation: remove it and the recording comes back a second short, with
    // every sample after the outage claiming a time it did not happen at.
    try temporaryTrack("failed-writes-unpadded") { track, _ in
        let buffers = healthyStream(seconds: 3.0)
        for (index, buffer) in buffers.enumerated() where !(10..<20).contains(index) {
            try track.append([Float](repeating: 0.5, count: buffer.frames))
        }
        #expect(track.frameCount == Int64(2.0 * replayRate))
        #expect(track.frameCount < Int64(3.0 * replayRate))
    }
}
