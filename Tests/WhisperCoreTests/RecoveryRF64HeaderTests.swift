import Foundation
import Testing
@testable import WhisperCore

// F336 — the rebuild reserves its header from `totalFrames` and writes it from `writtenFrames`, and
// unlike `FloatTrackMixer.mix` — whose loop always reaches `totalFrames` — `mixTracks` returns
// fewer when a track becomes unreadable mid-rebuild. A rebuild long enough to need RF64 that then
// truncates below the limit therefore reserved 80 bytes and wrote a 44-byte classic header, leaving
// 36 zero bytes inside the declared `data` range: the audio shifted by 18 frames and the last 18
// frames outside the declared size, with every integrity check still passing
// (`44 + written*2 <= 80 + written*2`).
//
// It went unnoticed because this second WAV writer had no `classicDataLimit` seam, so its RF64
// branch was never executed by any test at all.

private struct ReadFailure: Error {}

@Test("A truncated rebuild past the RF64 boundary writes the header it reserved (F336)")
func truncatedRF64RebuildWritesTheHeaderItReserved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F336-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // 20,000 declared frames — 40,000 bytes of PCM — against a limit of 20,000, so the reserve is
    // RF64. The reader dies after the first 8,192-frame chunk, so only 16,384 bytes are written,
    // which is *under* the same limit.
    try Data(repeating: 0, count: 20_000 * 4)
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
        },
        classicDataLimit: 20_000
    ))

    let wav = try Data(contentsOf: recovered.recordingURL)
    #expect(wav.prefix(4) == Data("RF64".utf8), "the reserve was 80 bytes, so the header must fill them")
    let declaredDataBytes = wav.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 28, as: UInt64.self).littleEndian
    }
    #expect(declaredDataBytes == UInt64(8_192 * 2), "the bytes actually written, not the ones promised")
    #expect(wav.count == 80 + 8_192 * 2, "no gap between the header and the first sample")
}

@Test("An untruncated rebuild past the boundary is RF64 end to end (F336)")
func fullRF64RebuildIsWellFormed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F336-full-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 0, count: 20_000 * 4)
        .write(to: directory.appendingPathComponent("system-audio.f32"))

    let recovered = try #require(try InterruptedRecordingRecovery.recover(
        in: directory,
        sampleRate: 48_000,
        openTrack: { url in
            guard url != nil else { return { [Float](repeating: 0, count: $0) } }
            return { [Float](repeating: 0.5, count: $0) }
        },
        classicDataLimit: 20_000
    ))

    let wav = try Data(contentsOf: recovered.recordingURL)
    #expect(wav.prefix(4) == Data("RF64".utf8))
    let declaredDataBytes = wav.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 28, as: UInt64.self).littleEndian
    }
    #expect(declaredDataBytes == UInt64(20_000 * 2))
    #expect(wav.count == 80 + 20_000 * 2)
}
