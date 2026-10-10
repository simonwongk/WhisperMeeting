import CryptoKit
import Foundation
import Testing
@testable import WhisperCore

// F910 — the mixer at Stop and the interrupted-recording rebuild read both Float32 tracks a chunk at
// a time with `FileHandle.read(upToCount:)`, which returns each chunk in an autoreleased buffer.
// Each loop runs inside one job: `AudioCaptureEngine.stop()` calls `FloatTrackMixer.mix`
// synchronously, and the rebuild runs inside `Task.detached`. With no pool drained per chunk, every
// chunk stayed allocated until the call returned. Measured with two 64 MiB tracks: +134,938,720
// bytes of footprint across one `mix` and +135,397,472 across one `recover`, the shape the lane L
// review found in F533's decode read. Both are measured here as F533's are: what ONE direct call
// left held (`heldMemory`), over dense temporary tracks.

/// Two dense 16 MiB tracks: 4,194,304 frames each, 87 s at 48 kHz.
private struct DenseTracks {
    let directory: URL
    let system: URL
    let microphone: URL
    let frames = Int64(16 << 20) / Int64(MemoryLayout<Float>.size)

    init(_ label: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F910-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        system = directory.appendingPathComponent("system-audio.f32")
        microphone = directory.appendingPathComponent("microphone-audio.f32")
        try writeDenseFile(at: system, mebibytes: 16, seed: 910)
        try writeDenseFile(at: microphone, mebibytes: 16, seed: 911)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// The PCM a mix of these tracks must hold: every frame through the one gain rule,
    /// `FloatTrackMixer.mixedSample`, worked out here with no chunking and no pools.
    func expectedPCM() throws -> Data {
        let system = try Data(contentsOf: self.system, options: .alwaysMapped)
        let microphone = try Data(contentsOf: self.microphone, options: .alwaysMapped)
        var pcm = [Int16](repeating: 0, count: Int(frames))
        system.withUnsafeBytes { systemBytes in
            microphone.withUnsafeBytes { microphoneBytes in
                for index in pcm.indices {
                    pcm[index] = FloatTrackMixer.mixedSample(
                        system: systemBytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self),
                        microphone: microphoneBytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                    )
                }
            }
        }
        return pcm.withUnsafeBytes { Data($0) }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test("Mixing two tracks at Stop holds one chunk of each at a time, and writes exactly the per-frame mix (F910)")
func mixingTwoTracksHoldsOneChunkAtATime() throws {
    let tracks = try DenseTracks("mix")
    defer { tracks.remove() }
    let output = tracks.directory.appendingPathComponent("meeting.wav")
    var duration: TimeInterval = 0

    let held = try heldMemory {
        duration = try FloatTrackMixer.mix(
            system: FloatTrack(url: tracks.system, firstPresentationTime: 0, frameCount: tracks.frames),
            microphone: FloatTrack(url: tracks.microphone, firstPresentationTime: 0, frameCount: tracks.frames),
            sampleRate: 48_000,
            outputURL: output
        )
    }

    #expect(duration == Double(tracks.frames) / 48_000)
    // Every chunk kept is both tracks, 32 MiB; one chunk of each at a time is 64 KiB.
    #expect(held.allocated < 8 << 20, "mixing two 16 MiB tracks left \(held) held")
    #expect(held.footprint < 8 << 20, "mixing two 16 MiB tracks left \(held) held")
    // The pool changes what is held, never what is written: the canonical header, then every frame
    // through the gain rule.
    let written = try Data(contentsOf: output, options: .alwaysMapped)
    #expect(written.prefix(44) == WAVWriter.header(sampleRate: 48_000, dataByteCount64: UInt64(tracks.frames) * 2))
    #expect(written.dropFirst(44) == (try tracks.expectedPCM()), "the mix is not the per-frame rule")
    // And the very bytes the mixer wrote before its reads were pooled: F910's RED run, on the unpooled
    // mixer, wrote this SHA-256 for these tracks. If the gain rule is ever changed on purpose this
    // digest moves with it; the per-frame check above says whether the streaming is still right.
    #expect(sha256(written) == "4c621392742264a86207a35bb9c1385719c8a8e2c85c20c21ee6307e0c0d9e28")
}

@Test("Rebuilding an interrupted recording holds one chunk of each track at a time, and writes exactly the per-frame mix (F910)")
func rebuildingFromTracksHoldsOneChunkAtATime() throws {
    let tracks = try DenseTracks("rebuild")
    defer { tracks.remove() }
    var recovered: RecoveredRecording?

    let held = try heldMemory { recovered = try InterruptedRecordingRecovery.recover(in: tracks.directory) }

    let rebuilt = try #require(recovered)
    #expect(rebuilt.source == .rebuiltSourceTracks)
    #expect(rebuilt.truncatedAtSeconds == nil)
    #expect(held.allocated < 8 << 20, "rebuilding from two 16 MiB tracks left \(held) held")
    #expect(held.footprint < 8 << 20, "rebuilding from two 16 MiB tracks left \(held) held")
    let written = try Data(contentsOf: rebuilt.recordingURL, options: .alwaysMapped)
    #expect(written.count == 44 + Int(tracks.frames) * 2)
    #expect(written.dropFirst(44) == (try tracks.expectedPCM()), "the rebuild is not the per-frame rule")
}
