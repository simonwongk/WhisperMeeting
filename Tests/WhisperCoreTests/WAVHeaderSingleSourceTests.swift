import Foundation
import Testing
@testable import WhisperCore

// F278 — `WAVWriter.swift:3-4` claims to be "exactly one WAV path in the codebase". It was not:
// `InterruptedRecordingRecovery` carried its own byte-for-byte reimplementation (`:293-309`).
//
// A correction to the record: the earlier review said **three** copies and I repeated that in F259's
// log entry and in F278's own text without checking. There were two. `FloatTrackMixer` already calls
// `WAVWriter.header` (`AudioCaptureEngine.swift:796`), as do the dictation clip writer
// (`AppModel.swift:1394`) and the diarization smoke test. Same failure as the fsync figure: a
// plausible number, asserted and repeated, never verified.
//
// Two copies still matter, because **F150** — the `UInt32` data-size field overflowing past ~12.4 h
// of audio — has to be fixed in every one, and the duplicate was in the path that runs *after* an
// interruption, i.e. exactly when correctness matters most.
//
// These tests pin the bytes so collapsing the duplicate onto `WAVWriter.header` cannot change what
// lands on disk.

@Test("The canonical header is 44 bytes with the expected RIFF/WAVE layout (F278)")
func canonicalHeaderLayout() {
    let header = WAVWriter.header(sampleRate: 48_000, dataByteCount: 363_048_960)
    #expect(header.count == 44)

    func ascii(_ range: Range<Int>) -> String { String(decoding: header[range], as: UTF8.self) }
    func le32(_ offset: Int) -> UInt32 {
        header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    func le16(_ offset: Int) -> UInt16 {
        header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    #expect(ascii(0..<4) == "RIFF")
    #expect(le32(4) == 36 + 363_048_960)          // RIFF chunk size
    #expect(ascii(8..<12) == "WAVE")
    #expect(ascii(12..<16) == "fmt ")
    #expect(le32(16) == 16)                        // fmt chunk size
    #expect(le16(20) == 1)                         // PCM
    #expect(le16(22) == 1)                         // mono
    #expect(le32(24) == 48_000)                    // sample rate
    #expect(le32(28) == 96_000)                    // byte rate = rate * 2
    #expect(le16(32) == 2)                         // block align
    #expect(le16(34) == 16)                        // bits per sample
    #expect(ascii(36..<40) == "data")
    #expect(le32(40) == 363_048_960)               // data size — the field F150 is about
}

@Test("The header a recovery rebuild writes is byte-identical to the canonical one (F278)")
func recoveryHeaderMatchesCanonical() throws {
    // The collapse this protects: `InterruptedRecordingRecovery` built its own header. Rather than
    // comparing two functions, read the bytes a real rebuild actually produced — that is what has to
    // stay the same, and it is the only version a user ever sees.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F278-header-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var samples = Data(capacity: 240 * 4)
    for _ in 0..<240 {
        var value = Float(0.5).bitPattern.littleEndian
        withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
    }
    try samples.write(to: directory.appendingPathComponent("system-audio.f32"))
    try Data().write(to: directory.appendingPathComponent("microphone-audio.f32"))

    let rebuilt = try InterruptedRecordingRecovery.recover(in: directory, sampleRate: 48_000)
    let recovered = try #require(rebuilt)
    let wav = try Data(contentsOf: recovered.recordingURL)

    let expected = WAVWriter.header(sampleRate: 48_000, dataByteCount: 240 * 2)
    #expect(wav.prefix(44) == expected,
            "a rebuild's header diverged from WAVWriter's — the duplicate is back")
}

@Test("A sample rate that would overflow the byte-rate field does not trap (F278)")
func headerToleratesAnAbsurdSampleRate() {
    // `WAVWriter` uses `&*` and `&+`; the duplicate used `*`, which traps rather than wrapping.
    // Neither is *correct* past the field's range — that is F150 — but the canonical one at least
    // cannot crash the app while finalizing a recording, which is the worse of the two failures.
    let header = WAVWriter.header(sampleRate: .max, dataByteCount: .max)
    #expect(header.count == 44)
}
